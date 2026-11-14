# Changing or updating a finished system

A finished VM is **locked**: egress is on the runtime policy and the
agent user has no `sudo`. Everything here works on a locked VM unless it
says otherwise. Each of these ends the same way — `./verify/verify.sh`,
and a message to the bot.

## Changing a value in `config/agents.env`

A bot token, an agent's name, the timezone, a model.

```sh
$EDITOR config/agents.env          # the user does this; never in a chat
./bootstrap.sh                     # validates it and re-pushes; the VM stays locked
./scripts/pi-session.sh say "config/agents.env changed. Re-apply it with setup.sh and say what changed."
./verify/verify.sh --models
```

Pushing the file is not enough by itself. The agents hold their own
copies — Hermes in `~/.hermes/.env`, OpenClaw in `openclaw.json` — and
Pi's `setup.sh` is what carries a new value into them. **This path has
not been exercised end to end**: `setup.sh` guards on what it finds, so a
guard may decide nothing needs doing. Read `pi-session.sh steps`, and
trust `verify.sh` over Pi's summary.

A changed **model** is the case most worth checking: `verify.sh` prints
what both agents actually run, every time.

## Updating OpenClaw or Hermes

Both are installed from the vendor's latest, so nothing here pins a
version; `verify.sh` prints the versions it found. To move to a newer
one:

```sh
./verify/verify.sh                 # note the Versions lines first
./scripts/pi-session.sh say "Update Hermes to the current release with its own updater, then re-run setup.sh and report both versions."
./verify/verify.sh --models
```

Then re-run every add-on's `verify`, because an update is exactly what
breaks them — see below. Run the vendors' doctors on parsed output, never
exit code (`AGENTS.md`).

If the update needs root, reopen the build phase first and lock it
again afterwards:

```sh
./scripts/install-config.sh --reopen
...
./scripts/finish-build.sh
```

Between those two commands the agents can `sudo`, and their Telegram
bots are live. Keep it short.

## After a Hermes update, re-apply the Google add-on

A Hermes update builds a new environment and restores its bundled
skills. That silently removes two things the add-on put there: PySocks,
without which every Google call bypasses the proxy and hangs, and the
contacts patch. Nothing fails at update time. So:

```sh
./scripts/addon-google-hermes.sh verify --live
./scripts/addon-google-hermes.sh build      # only if verify says so
```

## If `config/admin-secret` is lost

That file is the host's only way to root in a locked VM. Without it the
scripts cannot re-push egress policy or reopen the build phase, and
`verify.sh` cannot read policy state. The agents keep running. The way
back is `./bootstrap.sh --rebuild`, which destroys them — so back the
file up with the rest of `config/`, off the repo.
