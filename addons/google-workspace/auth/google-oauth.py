#!/usr/bin/env python3
"""One-time Google OAuth consent, on the host, for the Hermes add-on.

Reads GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET from config/google.env,
walks the consent flow, and writes GOOGLE_REFRESH_TOKEN and
GOOGLE_ACCOUNT_EMAIL back into the same file at 0600.

Standard library only, deliberately. This runs on the user's machine before
anything is installed, so it cannot assume a venv, and asking someone to pip
install a dependency in order to supply a credential is a poor first step.

The VM never runs this. It has no browser and no display, and the whole
point of doing consent on the host is that the sandbox never needs one.
"""

import base64
import hashlib
import http.server
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

AUTH_URI = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URI = "https://oauth2.googleapis.com/token"
USERINFO_URI = "https://openidconnect.googleapis.com/v1/userinfo"

# These eight must match Hermes' bundled google-workspace skill exactly,
# scope for scope. Its setup.py checks the token's recorded scopes against
# its own SCOPES list and reports "AUTHENTICATED (partial)" for any it does
# not find -- so a list that merely overlaps is not good enough.
#
# Gmail deliberately stops at gmail.modify rather than
# https://mail.google.com/: under modify the API refuses permanent
# deletion, so "trash only" is Google's rule, not ours. Drive takes the
# full scope because Google publishes no read/write/no-delete scope for it;
# unlike the MCP server this replaces, the skill CAN delete Drive files.
# Said plainly in README.md rather than left to be discovered.
GOOGLE_SCOPE = "https://www.googleapis.com/auth/"
SKILL_SCOPES = [
    GOOGLE_SCOPE + "gmail.readonly",
    GOOGLE_SCOPE + "gmail.send",
    GOOGLE_SCOPE + "gmail.modify",
    GOOGLE_SCOPE + "calendar",
    GOOGLE_SCOPE + "drive",
    # Read-only, because that is all the skill implements: google_api.py
    # has one contacts subcommand, `contacts list`. Asking for write here
    # would grant more than anything can use. The MCP server this replaces
    # did have contacts write; regaining it is deferred, see README.md.
    GOOGLE_SCOPE + "contacts.readonly",
    GOOGLE_SCOPE + "spreadsheets",
    GOOGLE_SCOPE + "documents",
]

# openid/userinfo.email are only how we learn which account consented.
# They are requested but not recorded as granted API scopes.
SCOPES = ["openid", GOOGLE_SCOPE + "userinfo.email"] + SKILL_SCOPES

# What goes in the token file's "scopes" list. Keep it exactly SKILL_SCOPES:
# the skill's _stored_token_scopes() reads this list and silently falls back
# to its own full set if it is absent or empty, which would hide a mismatch.
API_SCOPES = list(SKILL_SCOPES)

BOLD, RED, YELLOW, GREEN, OFF = "\033[1m", "\033[31m", "\033[33m", "\033[32m", "\033[0m"
if not sys.stdout.isatty():
    BOLD = RED = YELLOW = GREEN = OFF = ""


def say(msg):
    print(f"{BOLD}==>{OFF} {msg}", file=sys.stderr)


def ok(msg):
    print(f"{GREEN}  ok{OFF}  {msg}", file=sys.stderr)


def die(msg):
    print(f"{RED}error:{OFF} {msg}", file=sys.stderr)
    sys.exit(1)


def read_client_json(repo):
    """Read a client_secret_*.json downloaded from Cloud Console.

    Offered because retyping a client id is how a leading space got into
    one and cost an afternoon of invalid_client. The download button is
    right there on the credentials page; copying the file is fewer steps
    and cannot mistype.

    Returns (client_id, client_secret, path) or (None, None, None).
    """
    import glob
    found = sorted(glob.glob(os.path.join(repo, "secrets", "client_secret_*.json")))
    if not found:
        return None, None, None
    if len(found) > 1:
        die("more than one client_secret_*.json in secrets/:\n       "
            + "\n       ".join(os.path.basename(p) for p in found)
            + "\n       Leave only the one you want to use.")

    path = found[0]
    try:
        with open(path) as fh:
            blob = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        die(f"could not read {path}: {exc}")

    # Desktop clients are filed under "installed"; web ones under "web",
    # and a web client cannot do the loopback redirect this flow needs.
    if "web" in blob and "installed" not in blob:
        die(f"{os.path.basename(path)} is a {BOLD}Web application{OFF} client.\n"
            "       This flow needs a Desktop app client -- a web one rejects the\n"
            "       loopback redirect. Create one in Cloud Console -> Credentials\n"
            "       -> Create credentials -> OAuth client ID -> Desktop app.")
    section = blob.get("installed") or {}
    cid = (section.get("client_id") or "").strip()
    sec = (section.get("client_secret") or "").strip()
    if not cid or not sec:
        die(f"{os.path.basename(path)} has no client_id/client_secret under\n"
            "       an \"installed\" key. Re-download it from Cloud Console.")
    return cid, sec, path


def read_env(path):
    """Parse the shell-style env file without executing it."""
    values = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                # Strip whitespace inside the quotes as well as outside: a
                # client id pasted with a leading space is answered by
                # Google with "Error 401: invalid_client -- The OAuth
                # client was not found", which sends you looking in the
                # Cloud Console for a client that is perfectly fine.
                values[key.strip()] = val.strip().strip('"').strip("'").strip()
    except FileNotFoundError:
        # Not an error. `auth` runs before `install` in the documented
        # order, and `install` is what creates this file -- so dying here
        # made the first command anyone runs fail, with a message naming
        # the OAuth client (which is fine) instead of the missing file.
        # An absent env file simply means nothing has been written yet;
        # the client comes from secrets/client_secret_*.json, and the
        # values this function would supply are written back later.
        return {}
    return values


def write_env_value(path, key, value):
    """Replace or append one key, preserving comments and ordering.

    Rewrites through a 0600 temp file and renames: a crash partway through
    must not leave a half-written credentials file behind.
    """
    # May not exist yet: `auth` can legitimately run before `install`, and
    # then this is the call that creates the file. The 0600 temp-and-rename
    # below gives it the right mode either way.
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except FileNotFoundError:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        lines = []

    # Google's tokens are [A-Za-z0-9._/+=~-], but this file gets sourced by
    # tooling, so refuse rather than emit a line that could break quoting.
    if any(c in value for c in '"\\\n\r`$'):
        die(f"refusing to write {key}: the value contains a quoting character.")

    replaced = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith(f"{key}="):
            lines[i] = f'{key}="{value}"\n'
            replaced = True
            break
    if not replaced:
        if lines and not lines[-1].endswith("\n"):
            lines.append("\n")
        lines.append(f'{key}="{value}"\n')

    tmp = f"{path}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.writelines(lines)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def write_json_0600(path, payload):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(payload, fh, indent=2)
    os.chmod(path, 0o600)


def write_token_json(path, refresh, client_id, client_secret):
    """Write google_token.json in the shape Hermes' skill reads.

    google-auth's Credentials.from_authorized_user_file requires exactly
    refresh_token, client_id and client_secret, and raises without them.
    The skill's _normalize_authorized_user_payload injects type=
    authorized_user when absent, so writing it is belt and braces.

    No `token` and no `expiry`: google-auth treats a credential with no
    expiry as already expired, so the first use refreshes against Google
    rather than trusting anything we minted here. That is what lets consent
    happen on the host and the token be used in a VM with no browser.
    """
    write_json_0600(path, {
        "type": "authorized_user",
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh,
        "token_uri": TOKEN_URI,
        "scopes": API_SCOPES,
    })


def write_client_secret_json(path, src_path, client_id, client_secret):
    """Write google_client_secret.json, verbatim from Google where possible.

    Nothing reads this at runtime -- the skill's google_api.py assigns
    CLIENT_SECRET_PATH and never opens it, because refreshing uses the id
    and secret inside the token file. It exists because the skill's
    SKILL.md declares it under required_credential_files, and Hermes' cron
    preflight refuses to start any job whose declared credential file is
    missing. That refusal is what blocked the first inbox digest.

    The skill only validates that a top-level "installed" or "web" key is
    present, so Google's own download satisfies it. We reconstruct the file
    only when the user supplied the id and secret by hand instead.
    """
    if src_path:
        try:
            with open(src_path) as fh:
                write_json_0600(path, json.load(fh))
            return
        except (OSError, json.JSONDecodeError):
            pass
    write_json_0600(path, {"installed": {
        "client_id": client_id,
        "client_secret": client_secret,
        "auth_uri": AUTH_URI,
        "token_uri": TOKEN_URI,
    }})


def post_form(url, fields):
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        die(f"Google rejected the token request ({exc.code}):\n{detail}")


PAGE = """<!doctype html><meta charset=utf-8>
<title>{title}</title>
<body style="font-family:system-ui;margin:4rem auto;max-width:34rem">
<h1>{title}</h1><p>{body}</p></body>"""


class Handler(http.server.BaseHTTPRequestHandler):
    result = None
    expected_state = None

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/":
            self.send_error(404)
            return
        params = urllib.parse.parse_qs(parsed.query)
        Handler.result = params

        # Judge the response here too, so the page the user is looking at
        # agrees with what the terminal is about to tell them.
        if params.get("state", [None])[0] != Handler.expected_state:
            title, body = "Consent rejected", "That response did not match this request, so it was discarded."
        elif "code" in params:
            title, body = "Consent received", "You can close this tab and go back to the terminal."
        else:
            err = params.get("error", ["no authorization code"])[0]
            title, body = "Consent failed", f"Google said: {err}"

        page = PAGE.format(title=title, body=body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *args):
        pass


def try_open_browser(url):
    """Best effort. Returns True only if we have reason to think it worked."""
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return False
    opener = "open" if sys.platform == "darwin" else "xdg-open"
    try:
        subprocess.run([opener, url], check=True, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def main():
    # addons/google-workspace/auth/this-file -> up four to the repo root.
    here = os.path.abspath(__file__)
    repo = os.path.normpath(os.path.join(os.path.dirname(here), "..", "..", ".."))
    env_path = os.path.join(repo, "config", "google.env")
    url_path = os.path.join(repo, "config", "google-consent-url.txt")
    port = int(os.environ.get("GOOGLE_OAUTH_PORT", "8731"))

    env = read_env(env_path)

    # The downloaded JSON wins when it is there. It cannot be mistyped,
    # and it carries the client type, so a Web client is caught here
    # rather than at the redirect.
    client_id, client_secret, from_json = read_client_json(repo)
    if from_json:
        source = f"secrets/{os.path.basename(from_json)}"
        ok(f"read the OAuth client from {source}")
        write_env_value(env_path, "GOOGLE_CLIENT_ID", client_id)
        write_env_value(env_path, "GOOGLE_CLIENT_SECRET", client_secret)
    else:
        source = str(env_path)
        client_id = env.get("GOOGLE_CLIENT_ID", "")
        client_secret = env.get("GOOGLE_CLIENT_SECRET", "")

    if not client_id or not client_secret:
        die("no OAuth client credentials yet.\n"
            "       Easiest: in Cloud Console -> APIs & Services -> Credentials,\n"
            "       press the download icon beside your Desktop client and put the\n"
            "       file in  secrets/  -- it is named client_secret_*.json and is\n"
            "       gitignored. Nothing to copy by hand.\n"
            f"       Or fill GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in {env_path}.")

    # Check the shape before Google does. Its answer to a malformed client
    # id is "Error 401: invalid_client -- The OAuth client was not found",
    # which points at the Cloud Console rather than at the typo, and costs
    # a round trip through a browser on another machine to discover.
    if not re.match(r"^\d+-[A-Za-z0-9_]+\.apps\.googleusercontent\.com$", client_id):
        hint = ""
        if client_id.endswith(".apps.googleusercontent.com"):
            hint = ("\n       The suffix is right, so this is likely a stray character:\n"
                    "       check for a space, a quote or a line break inside the value.")
        die(f"the client id from {source} is not well formed.\n"
            f"       Expected  <digits>-<letters>.apps.googleusercontent.com\n"
            f"       Got       {len(client_id)} characters"
            f"{hint}\n"
            "       Simplest fix: download the JSON from Cloud Console into\n"
            "       secrets/ and let this command read it.")

    if not re.match(r"^GOCSPX-[A-Za-z0-9_-]+$", client_secret):
        die(f"the client secret from {source} does not look like one.\n"
            "       Google's start with 'GOCSPX-'. Check for a stray space or\n"
            "       quote, and that you did not paste the client id twice.")

    if env.get("GOOGLE_REFRESH_TOKEN") and "--force" not in sys.argv:
        say("a refresh token is already present; nothing to do.")
        say("re-consent anyway with: addon-google-workspace.sh auth --force")
        return

    # PKCE. A desktop client secret ships inside the app and is not really a
    # secret, so the code verifier is what actually binds this exchange to
    # this process.
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)
    redirect_uri = f"http://127.0.0.1:{port}/"

    consent_url = AUTH_URI + "?" + urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": " ".join(SCOPES),
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        # Without both of these Google returns no refresh token on a repeat
        # consent, and the add-on then works until the first access token
        # expires an hour later.
        "access_type": "offline",
        "prompt": "consent",
    })

    Handler.expected_state = state
    try:
        httpd = http.server.HTTPServer(("127.0.0.1", port), Handler)
    except OSError as exc:
        die(f"could not listen on 127.0.0.1:{port} ({exc}).\n"
            f"       Something else is using it. Pick another with:\n"
            f"         GOOGLE_OAUTH_PORT=8732 ./scripts/addon-google-workspace.sh auth\n"
            f"       Nothing to change in the Cloud Console -- a Desktop client\n"
            f"       accepts any loopback port. Use the same number in your\n"
            f"       ssh -L tunnel.")

    with open(url_path, "w") as fh:
        fh.write(consent_url + "\n")
    os.chmod(url_path, 0o600)

    say("waiting for Google consent")
    if try_open_browser(consent_url):
        ok("opened your browser")
    else:
        # Headless box over SSH: the normal case for this repo. Print the
        # URL in full rather than pointing at a file -- a terminal is a
        # thing you select text in, and sending someone to `cat` a file in
        # a fourth window to get it was a worse experience than a long
        # line that wraps. The file stays, for anyone who would rather scp
        # it.
        user = os.environ.get("USER", "user")
        host = socket.gethostname()
        print(f"""
  {YELLOW}No browser here.{OFF} Two things to do on your laptop. This command is
  waiting for up to 10 minutes; leave it running.

  {BOLD}1.{OFF} On your laptop -- any shell there, as long as it is not SSHed
     into this machine -- open the tunnel. This backgrounds itself and
     gives you your prompt straight back:

         {BOLD}ssh -f -N -L {port}:127.0.0.1:{port} {user}@{host}{OFF}

     (Drop the -f if you would rather watch it; then it prints nothing
     and does not return, which is also it working.)

  {BOLD}2.{OFF} Paste this into your laptop's browser and approve:

{BOLD}{consent_url}{OFF}

  Then this command finishes by itself. Close the tunnel afterwards, on
  the laptop, with
      pkill -f 'ssh -f -N -L {port}'    (Ctrl-C instead, if you skipped -f)

  (The URL is also in config/google-consent-url.txt if you would rather
  scp it. Approving before the tunnel is up fails and burns the consent,
  so do 1 first. Ctrl-C to give up.)
""", file=sys.stderr)

    # serve_forever, not handle_request: a browser may fetch /favicon.ico
    # or probe the port first, and a single-shot handler would spend the
    # callback on that and then wait ten minutes for a request that has
    # already been and gone. do_GET 404s anything but "/", and only "/"
    # sets Handler.result.
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 600
        while Handler.result is None and time.monotonic() < deadline:
            time.sleep(0.2)
    except KeyboardInterrupt:
        die("cancelled.")
    finally:
        httpd.shutdown()
        httpd.server_close()

    params = Handler.result
    if params is None:
        die("timed out after 10 minutes with no response from Google.")
    if "code" not in params:
        die(f"consent was refused: {params.get('error', ['unknown'])[0]}")
    if params.get("state", [None])[0] != state:
        die("state mismatch -- discarding this response rather than trusting it.")

    say("exchanging the code for a refresh token")
    tokens = post_form(TOKEN_URI, {
        "client_id": client_id,
        "client_secret": client_secret,
        "code": params["code"][0],
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    })

    refresh = tokens.get("refresh_token")
    if not refresh:
        die("Google returned no refresh token. This happens when the account has\n"
            "       already consented to this client. Revoke it at\n"
            "       https://myaccount.google.com/permissions and run auth again.")

    req = urllib.request.Request(USERINFO_URI)
    req.add_header("Authorization", f"Bearer {tokens['access_token']}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            email = json.load(resp).get("email", "")
    except urllib.error.URLError:
        email = ""

    if not email:
        die("Google did not say which account consented, and the credential "
            "file is named after it.\n       Re-run auth; if it keeps "
            "happening, check that the userinfo.email scope is still granted.")

    write_env_value(env_path, "GOOGLE_REFRESH_TOKEN", refresh)
    write_env_value(env_path, "GOOGLE_ACCOUNT_EMAIL", email)

    # Both files are named exactly as the skill's required_credential_files
    # declares them. install.sh pushes them into $HERMES_HOME unchanged;
    # renaming either one re-creates the cron failure this replaced.
    config_dir = os.path.dirname(env_path)
    token_path = os.path.join(config_dir, "google_token.json")
    secret_path = os.path.join(config_dir, "google_client_secret.json")
    write_token_json(token_path, refresh, client_id, client_secret)
    write_client_secret_json(secret_path, from_json, client_id, client_secret)

    if os.path.exists(url_path):
        os.remove(url_path)

    ok(f"refresh token written to config/google.env (0600) for {email}")
    ok("google_token.json and google_client_secret.json written to config/ (0600)")
    say("next: ./scripts/addon-google-workspace.sh install")


if __name__ == "__main__":
    main()
