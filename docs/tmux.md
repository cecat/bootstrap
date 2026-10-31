# Surviving a dropped SSH session

A Pi build runs ~30 minutes and a rebuild longer. If your SSH connection
drops, anything started directly in that shell dies with it — on
2026-10-31 a network outage killed a build mid-turn twice. Run the work
inside tmux and it keeps going on the host without you.

## The four commands

```sh
tmux new -s b        # start (or: tmux attach -t b, if it already exists)
```

Then work normally — start Claude Code, run the build, whatever.

To leave without stopping anything, press **Ctrl-b** then **d**.
("detach"). You are back at your own shell; the work continues.

If SSH drops instead, you do not have to do anything — detaching is
automatic.

Reconnect, then:

```sh
tmux attach -t b     # back exactly where you were
tmux ls              # if you forget what is running
```

## That is the whole workflow

Start every session with `tmux attach -t b || tmux new -s b` and you are
always inside it. The session lives until the host reboots or you type
`exit`.

## Two things worth knowing

**Scrolling needs a key.** Ctrl-b then `[` enters scrollback; arrows and
PgUp work; `q` leaves. Your mouse wheel alone will not scroll.

**A detached build is still logging.** `logs/pi-last.log` is written
continuously, so `./scripts/pi-session.sh steps` tells you where a build
got to from any shell, attached or not.
