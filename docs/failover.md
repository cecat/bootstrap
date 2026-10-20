# Local model fallback — unverified

The design calls for remote models as primary and a local vLLM model on the
DGX Spark (`spark-ts`) as fallback. **None of it has been tested.** This file
records what is known so the next person does not mistake intent for fact.

## Why it is unverified

Tailscale on the build host was logged out and could not reach its control
plane (`fetch control key: ... connection reset`), so `spark-ts` was never
reachable. Tailscale is installed in the VM and deliberately not logged in.

Separately, the failover configuration syntax for all three agents — OpenClaw
provider failover, Hermes custom OpenAI-compatible endpoint, Pi custom provider
— was never confirmed against current documentation.

`spec/pi-target-state.md` therefore instructs Pi to check current docs, report which
syntax it used and where it found it, and **write nothing if the docs are
unclear**. A guessed failover config is worse than none: it fails silently at
the one moment you need it.

## Known issue: HTTPS on port 8000

The proxy config allows port 8000 for vLLM, but CONNECT is restricted to 443:

```
acl SSL_ports  port 443
http_access deny CONNECT !SSL_ports
```

So **plain HTTP to `spark-ts:8000` works; HTTPS on 8000 is refused.** If the
Spark serves vLLM over TLS on a non-443 port, add that port to `SSL_ports` in
`/etc/squid/squid.conf`. This was left unresolved rather than guessed at,
because the Spark's TLS setup is unknown.

## When the tailnet is back

1. `limactl shell agents -- sudo tailscale up` and confirm `spark-ts` resolves.
2. Confirm `spark-ts` is in `config/allowlist-runtime.conf`; re-run
   `scripts/install-config.sh` and `sudo agent-egress runtime`.
3. Fill in `VLLM_*` in `config/agents.env` and re-run the bootstrap so Pi
   writes the failover config against current docs.
4. Run the failover test: block the remote provider from inside the VM, then
   confirm each agent switches to vLLM **and completes a task that uses tools**.
   Tool calling is the part that breaks — the model needs auto tool choice, the
   right tool-call parser, and a context window large enough for the agents'
   system prompts and history.
5. Confirm agents ask before destructive actions while on the fallback model.

## Constraints to preserve

- Bind vLLM to the Tailscale or private interface only, with an API key set.
- Cap vLLM GPU memory utilization. Exhausting it has frozen SSH on the Spark.
- On the Spark, GPU workloads run in Docker with the NVIDIA runtime; the agent
  VM needs no GPU and reaches vLLM over a single allowed port.
