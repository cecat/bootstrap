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
from urllib.parse import quote

AUTH_URI = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URI = "https://oauth2.googleapis.com/token"
USERINFO_URI = "https://openidconnect.googleapis.com/v1/userinfo"

# Must match what workspace-mcp asks for, because the credential file we
# write records these as the granted scopes and the server trusts that
# record. Checked against its auth/scopes.py at version 2.3.0.
#
# Drive takes the full scope because Google publishes no read/write/no-delete
# scope for it; the no-delete rule comes from the server exposing no delete
# tool (verified -- see README.md). Gmail deliberately stops at
# gmail.modify rather than https://mail.google.com/: under modify the API
# refuses permanent deletion, so "trash only" is Google's rule, not ours.
SCOPES = [
    "openid",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.labels",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/drive.file",
    "https://www.googleapis.com/auth/forms.body",
    "https://www.googleapis.com/auth/forms.responses.readonly",
]

# Scopes recorded in the credential file. The two OIDC scopes above are
# only how we learn which account consented; the server never uses them,
# and listing them as granted API scopes would misrepresent the token.
API_SCOPES = [s for s in SCOPES if s.startswith("https://www.googleapis.com/auth/")
              and not s.endswith("/userinfo.email")]

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
        die(f"{path} does not exist. Run the install command once to create it.")
    return values


def write_env_value(path, key, value):
    """Replace or append one key, preserving comments and ordering.

    Rewrites through a 0600 temp file and renames: a crash partway through
    must not leave a half-written credentials file behind.
    """
    with open(path) as fh:
        lines = fh.readlines()

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


def write_credential_json(path, email, refresh, client_id, client_secret):
    """Write the credential file workspace-mcp's store expects.

    Its FileCredentialStore reads <url-encoded-email>.json from the
    credentials directory, with exactly these keys, and reconstructs a
    google.oauth2 Credentials from them (auth/credential_store.py at 2.3.0).

    Producing it here is what keeps a browser out of the VM: the server's
    own flow would otherwise want to open a consent page from inside the
    sandbox, which has no display and no way to reach one. A null `token`
    with a live `refresh_token` is the documented resting state -- the
    library mints an access token on first use.
    """
    payload = {
        "token": None,
        "refresh_token": refresh,
        "token_uri": TOKEN_URI,
        "client_id": client_id,
        "client_secret": client_secret,
        "scopes": API_SCOPES,
        "expiry": None,
    }
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(payload, fh, indent=2)
    os.chmod(path, 0o600)


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
    client_id = env.get("GOOGLE_CLIENT_ID", "")
    client_secret = env.get("GOOGLE_CLIENT_SECRET", "")
    if not client_id or not client_secret:
        die(f"GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET are blank in {env_path}.\n"
            "       Create an OAuth client of type 'Desktop app' in Google Cloud\n"
            "       Console and put both values in that file. The five steps are in\n"
            "       addons/google-workspace/README.md.")

    # Check the shape before Google does. Its answer to a malformed client
    # id is "Error 401: invalid_client -- The OAuth client was not found",
    # which points at the Cloud Console rather than at the typo, and costs
    # a round trip through a browser on another machine to discover.
    if not re.match(r"^\d+-[A-Za-z0-9_]+\.apps\.googleusercontent\.com$", client_id):
        hint = ""
        if client_id.endswith(".apps.googleusercontent.com"):
            hint = ("\n       The suffix is right, so this is likely a stray character:\n"
                    "       check for a space, a quote or a line break inside the value.")
        die(f"GOOGLE_CLIENT_ID in {env_path} is not a well-formed client id.\n"
            f"       Expected  <digits>-<letters>.apps.googleusercontent.com\n"
            f"       Got       {len(client_id)} characters"
            f"{hint}\n"
            "       Copy it again from Cloud Console -> APIs & Services ->\n"
            "       Credentials, and paste it with nothing either side.")

    if not re.match(r"^GOCSPX-[A-Za-z0-9_-]+$", client_secret):
        die(f"GOOGLE_CLIENT_SECRET in {env_path} does not look like a client\n"
            "       secret. Google's start with 'GOCSPX-'. Check for a stray space\n"
            "       or quote, and that you did not paste the client id twice.")

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

  Then this command finishes by itself. Close the tunnel afterwards with
      ssh -O exit {user}@{host}    (or just kill it, if you skipped -f)

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

    cred_path = os.path.join(os.path.dirname(env_path),
                             f"google-credentials-{quote(email, safe='@._-')}.json")
    write_credential_json(cred_path, email, refresh, client_id, client_secret)

    if os.path.exists(url_path):
        os.remove(url_path)

    ok(f"refresh token written to config/google.env (0600) for {email}")
    ok(f"credential file written to {os.path.basename(cred_path)} (0600)")
    say("next: ./scripts/addon-google-workspace.sh install")


if __name__ == "__main__":
    main()
