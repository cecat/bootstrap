# Resume here — paused 2026-10-29

Session paused mid-work. Nothing is running; the VM is up and the agents
are live. This file is scratch — delete it when the work lands.

## The build is one variable away from done

`verify.sh --models`: **35 passed, 1 failed.** The failure is
`Hermes answers a completion`.

Pi built everything else correctly on its first 30-minute run: both agents
installed, secrets as SecretRefs (`plaintext=0 unresolved=0`), Telegram
restricted to the configured user *before* going live, SOUL.md seeded for
both, proxy drop-ins present, idempotent setup script. **LuoJi answers on
Telegram.** Gandalf receives messages but cannot complete a model call.

### The one defect, diagnosed and unfixed

Measured inside the VM from a plain login shell:

```
CREDENTIAL           7 chars
ARGO_CREDENTIAL      7 chars
OPENROUTER_API_KEY   0 chars   <-- empty
OPENAI_API_KEY       0 chars   <-- empty
```

Hermes v0.22.5 with a custom provider reads `OPENROUTER_API_KEY`, which is
empty. Every other agent's variable resolves, and every other agent works.

The fix belongs in `~/agent-bootstrap/setup.sh` inside the VM (export it
alongside `CREDENTIAL`, same ANL username, as a reference not a literal —
and a systemd user service does not read `~/.profile`, so the gateway
drop-in needs it too). Then `hermes -z 'Reply with exactly: TRAV_OK'` must
actually print it, and `verify.sh --models` must pass.

**Do not fix this by hand in the VM.** Hand Pi the diagnosis above via
`./scripts/pi-session.sh say "..."`.

### Why this took all day, and the trap to avoid

A rejected credential **kills a stream mid-flight rather than returning
401**: `HTTP 200` then `transfer closed with outstanding read data
remaining`. So auth failures masquerade as network faults. Hours went into
theories about QEMU slirp, squid, the egress phase and credential
resolution — all disproven. All of them were disprovable in two minutes by
testing *the agents' actual request* instead of a convenient approximation.
`bash scripts/diag-stream.sh` does exactly that; run it first next time.

Already ruled out, do not re-litigate: slirp/long streams, squid (not in
the model path), the egress phase, request size, the model id form.

## What changed in the repo today

| | before | after |
|---|---|---|
| `todo.md` | 572 | 62 |
| `docs/gotchas.md` | — | 114 (new) |
| `scripts/pi-session.sh` | 129 | ~190 |
| `scripts/diag-stream.sh` | — | ~95 (new) |
| `archive/2026-10-29/` | — | 5,706-line snapshot, gitignored |

Nothing is committed yet. `git status` shows the lot.

`pi-session.sh` now **retries up to 5 times** (`PI_MAX_TRIES`) when a turn
produces no work, with 15/30/45/60s backoff, and kills a turn that exceeds
`PI_TIMEOUT` (default 45m). Both came from real failures today: three
consecutive transient errors, and then a turn that hung for 34 minutes with
an idle VM and an empty log. Only *no-work* failures retry — a turn where
Pi did something and then failed is a real result, and repeating it would
double the side effects of a script whose idempotence is what we are
testing.

**The retry/timeout path is untested.** It was written after the hang and
has not run.

## The simplification, agreed and half done

The repo was ~5,300 lines to install two agents in a VM. Pi got 34/35 right
in 30 minutes, which is the proof that no such volume was needed. The
mechanism was a ratchet: every failure earned a spec paragraph, a verify
check and an `AGENTS.md` warning, nothing ever had a deletion criterion, and
the resulting 749-line prompt made Pi slower and generated *new* failures.

Agreed targets:

| | now | target |
|---|---|---|
| `lima/agents.yaml` | 410 | ~350 |
| `verify.sh` | 632 | ~250 |
| `bootstrap.sh` + scripts | ~1,850 | ~200 |
| `spec/pi-target-state.md` | 749 | ~120 |
| `AGENTS.md` + docs | 1,715 | ~250 |
| `todo.md` | 572 | **62 done** |

Remaining: the spec cut, `AGENTS.md`, `verify.sh`, `bootstrap.sh`, and
extracting Pi's working `setup.sh` out of the VM as the deterministic build.

**Keep the egress sandbox** (squid allowlist + uid-scoped iptables) and the
egress assertions in `verify.sh`. A live agent has shell access and no
permission prompts, and `api.telegram.org` is allowlisted — the allowlist is
the only thing between a stranger and that shell. That part earned its
complexity; nearly everything else was accumulated apology.

**Hold the spec cut until Hermes verifies.** Cutting it while the build is
broken destroys the evidence of what the spec failed to say.
