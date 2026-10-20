# Local configuration

Everything in this directory is gitignored except the `*.example` templates and
this file. The repo is intended to go public; your usernames, agent names and
tokens stay on your machine.

## Setup

Copy each template, dropping the `.example` suffix, then fill it in:

```sh
cd config
for f in *.example; do cp -n "$f" "${f%.example}"; done
```

| File | What to put in it |
|---|---|
| `argoproxy.config.yaml` | Your ANL username in `user:`. Nothing else normally changes. |
| `agents.env` | Agent names and descriptions, gateway token, Telegram bot tokens, vLLM fallback details. |
| `allowlist-bootstrap.conf` | Extra hosts Pi needs while installing. Usually unchanged. |
| `allowlist-runtime.conf` | The steady-state egress allowlist. Uncomment `api.telegram.org` only after verification passes. |

## Checks

Nothing here is committed by accident:

```sh
git status --porcelain config/     # should list nothing but this README
git check-ignore -v config/agents.env
```

## Notes on secrets

Argo has no API key. It authenticates by ANL username plus network position,
so the VM must reach the Argonne network through host NAT and the Mac must be
on that network or its VPN. The username is low-value but still local detail,
so it is gitignored like everything else.

Real secrets in this setup are the OpenClaw gateway token, the Telegram bot
tokens and the vLLM key. Those live only inside the VM, are referenced as env
SecretRefs rather than written into configs, and must never be pasted into a
conversation with an agent.
