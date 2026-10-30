# Gotchas

**Audience: the coding agent supervising a build.** Not Pi. Pi reads
`spec/pi-target-state.md`, which describes the target state and nothing
else — every line added there makes Pi's context bigger and its job harder.
Things that went wrong once live here instead.

**Deletion rule.** Every entry is dated. **If a gotcha survives two clean
builds without mattering, delete it.** This file is allowed to shrink and is
expected to. The old repo had no deletion criterion, so nothing was ever
removed and the spec grew to 749 lines of accumulated apology. Do not
restart that ratchet.

Before adding an entry, ask: *is this a transient a supervisor should just
absorb?* Retry it, push back on Pi, work around it live. Only a repeatable
misunderstanding of the target earns a line here, and only a misunderstanding
of **what to build** belongs in the spec.

---

## Supervising Pi

**Pi over-claims. Read `verify.sh`, not the summary.** (2026-10-29) It
reported "✅ Setup Complete and Verified" with checkmarks and zero quoted
command output, over a build that was genuinely good but had one broken
agent. The summary is a claim; `verify.sh` is evidence. Note also that
`pi -p` emits only Pi's final answer, not its intermediate tool calls — so
"read the transcript" yields less than you would hope.

**But verify Pi before assuming it is wrong.** (2026-10-26) Three times in
one session a `verify.sh` check was wrong and Pi was right. Twice more on
2026-10-29: Pi's "OpenClaw uses a `models` array, not `defaultModel`" was
correct, and the spec's `$ARGO_CREDENTIAL` turned out to resolve fine.

**A failed Pi turn that produced one API error is not a failed build.**
(2026-10-29) `pi -p` sometimes dies before the first token. Nothing in the
VM changed. Re-run it. Three such failures in a row cost an hour of
theorising about slirp, squid and credential resolution; the fourth attempt
worked unchanged.

## The model path

**A rejected credential kills a stream mid-flight rather than returning
401.** (2026-10-29) Reproduced: an invalid ANL username gives `HTTP 200`
followed by `transfer closed with outstanding read data remaining`. An
*empty* key behaves differently — argo-proxy falls back to its own user and
returns a clean 200. So "stream ended before completion", `ArgoAuthWarning`
and `[Errno 104] Connection reset by peer` are all plausibly **auth**
symptoms, not network ones.

**Test the agents' actual path, not a convenient approximation.**
(2026-10-29) Every green check we had sent either no credential or a
hand-supplied one, and every one passed `--noproxy '*'`. The agents do
neither. An hour went into theories that a two-minute matched test killed.
`scripts/diag-stream.sh` exists for this: it varies stream length, the proxy
setting, the model id, request size and credential validity.

**Ruled out on this host, do not re-litigate** (2026-10-29): QEMU slirp on
long streams (3000 tokens, 6.5s, clean), squid (not in the model path at
all — the gateway is a direct uid-scoped ACCEPT), the egress phase (that
iptables rule is byte-identical in both phases), request size (90 KB fine),
and the model id form.

**`/health` and `/v1/models` are false greens.** They answer 200 from local
state with a dead upstream. Only a completion proves the path.

**`VM_BASE_URL`, never `UPSTREAM_BASE_URL`.** The latter is the host's
address, often `127.0.0.1:<port>`, which from inside the VM is nothing.

**A systemd user service does not read `~/.profile`.** Without a proxy
drop-in the gateway reaches the model fine (direct, uid-allowed) and fails
every allowlisted destination with `EHOSTUNREACH` — passing `--models`
30/30 while unable to reach a single chat channel.

**Each agent reads its own credential variable.** (2026-10-29) `CREDENTIAL`
and `ARGO_CREDENTIAL` both resolve; Hermes with a custom provider wanted
`OPENROUTER_API_KEY`, which was empty — the one real defect in an otherwise
clean build. If one agent fails while others pass, check its variable before
anything else.

## Host and VM

**Editing `lima/agents.yaml` does not change an existing VM.** Lima copies
the config in at creation and re-reads *that* copy on boot. Use `--rebuild`;
cheap before Pi has built, destructive after.

**On the DGX Spark:** use the `kvm` group, not `setfacl` — a `setfacl` grant
on `/dev/kvm` does not survive the udev event that installing qemu triggers
(`sg kvm -c '...'` for an already-running shell). NextDNS blocks the NVIDIA
apt repos, which looks alarming during `apt-get update` and is irrelevant.

**The host must be on the network its model endpoint needs.** The VM
inherits host NAT.

## Writing checks

**When you find a defect, the fix is a check that fails on it** — not prose
in the spec. But check the tool's *actual* model first: several `verify.sh`
checks have been wrong because they asserted what output looks like rather
than what the system does.

**Do not grep multi-line JSON with a single-line pattern.** A guard like
`grep -q '"botToken".*"source":"env"'` never matches pretty-printed JSON, so
its step runs unconditionally while looking guarded. Use `jq -e`.

**Watch for skips reading as passes.** In a thirty-line run `SKIP` looks
like `PASS`. `--idempotence` skips under the runtime allowlist because Pi's
`setup.sh` needs pypi.org, which is why `finish-build.sh` runs it before
narrowing egress.

**Mind your own pipes.** (2026-10-29) Piping `finish-build.sh` through
`tail` reported tail's exit code, so a run that printed "The build is NOT
proven" was announced as a success. The repo's own failure mode, committed
by the supervisor.
