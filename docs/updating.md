# Changing or updating a finished system

A finished VM is **locked**: egress is on the runtime policy and the
agent user has no `sudo`. Everything here works on a locked VM unless it
says otherwise. Each of these ends the same way — `./verify/verify.sh`,
and a message to the bot.

## First: do not re-run Pi's `setup.sh` on a VM with history

`~/agent-bootstrap/setup.sh` is written by Pi at build time and is the
build's deliverable. On a **fresh** VM, running it is how anything gets
applied. On a VM that has since been corrected in place it is a record
of how things were on build day, and running it puts them back.

That is not hypothetical. On 2026-11-16 Pi was told to "put the fix in
setup.sh and run it" on a VM built a week earlier. The script reset
OpenClaw's memory provider to `none` and wrote a `SOUL.md` into a
directory nothing loads — two defects that had each been found, fixed
in the spec and fixed in that VM days before. `verify.sh` caught both
on the next run; nothing else would have.

So on an existing VM, ask Pi for **the specific change**, tell it not to
run `setup.sh` as a whole, and have it bring the script's matching
section up to date without executing it. Then `./verify/verify.sh`, and
for anything touching memory or identity:

```sh
./scripts/diag-memory.sh           # does memory work, not merely look configured
./scripts/diag-workspace.sh        # what changed in the identity files, and when
```

## Bringing an older VM up to the current sandbox

A VM built before 2026-11-14 lets its agents reach every loopback
service on the host through squid, has no IPv6 lockdown, and leaves the
agent user with passwordless `sudo` (`docs/gotchas.md`). Rebuilding
fixes that and destroys the agents. This does not:

```sh
git pull                           # in the checkout the VM was built from
./scripts/upgrade-vm.sh            # asks first: it stops and starts the VM
```

The agents are off Telegram for a few minutes. Nothing under `~/.hermes`
or `~/.openclaw` is touched; the VM's old definition is kept beside the
new one, and the script prints how to go back. Afterwards, message each
bot, and re-run each add-on's `verify`.

Proven on 2026-11-16 on a VM built from the old definition with no
agents in it: six sandbox checks failing before, none after, and still
locked after a reboot. What that did not show is agents coming back
answering — watch for anything of theirs that relied on `sudo`.

## Changing a value in `config/agents.env`

A bot token, an agent's name, the timezone, a model.

```sh
$EDITOR config/agents.env          # the user does this; never in a chat
./bootstrap.sh                     # validates it and re-pushes; the VM stays locked
./scripts/pi-session.sh say "config/agents.env changed: <which value>. Apply that one change directly, update the matching part of setup.sh without running the script, and say what you changed."
./verify/verify.sh --models
```

Pushing the file is not enough by itself. The agents hold their own
copies — Hermes in `~/.hermes/.env`, OpenClaw in `openclaw.json` — and
Pi has to carry a new value into them. **This path has not been
exercised end to end.** Read `pi-session.sh steps`, and trust
`verify.sh` over Pi's summary.

A changed **model** is the case most worth checking: `verify.sh` prints
what both agents actually run, every time.

## Updating OpenClaw or Hermes

Both are installed from the vendor's latest, so nothing here pins a
version; `verify.sh` prints the versions it found. To move to a newer
one:

```sh
./verify/verify.sh                 # note the Versions lines first
./scripts/pi-session.sh say "Update Hermes to the current release with its own updater and report both versions. Do not run setup.sh."
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
