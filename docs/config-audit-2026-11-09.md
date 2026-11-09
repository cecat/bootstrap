# Configuration audit, 2026-11-09

Both agents' settings compared against their vendors' documentation, after
four gaps in three days reached the user as bad agent behaviour while a
41-check suite stayed green.

**The standard:** every setting is either deliberately set, or its default
has been read and deemed reasonable. A default someone examined and
accepted is fine. A default nobody looked at is the bug.

This file is the record of what was examined. Delete an entry once it is
in `spec/pi-target-state.md` and checked by `verify.sh` — the spec and the
suite are the deliverable; this is working notes.

## Verified against the running system

### Hermes compression — FIXED, and the fix is confirmed by telemetry

The audit argued the 4096 truncation was probably still live, reasoning
that `max_summary_tokens = min(context_length × 0.05, 12_000)` and that
`argo:claude-5-opus` would resolve to a 128K fallback window, giving 6400
— still over the cap.

Measured instead, from a successful compaction at 2026-11-09 08:27:

    main_context_limit:  200000      (not the 128K fallback assumed)
    effective_threshold: 60000       (our setting is what binds)
    aux_model:           argo:gemini-3.8-flash
    commit_status:       committed
    failure_class:       null
    messages:            23 -> 18

`summary_truncated_failure` appears 8 times in the logs, last at
**08:17:46**. The fix landed at 08:19. Nothing since. The ceiling is
`min(200000 × 0.05, 12000) = 10000`, but the *content* budget
(`content_tokens × 0.20`) is what actually governs at a 60K threshold, and
it lands under 4096.

**Lesson worth keeping:** the audit's arithmetic was correct and its
premise was wrong. Telemetry beat inference. Check
`main_context_limit` in the compression telemetry before trusting any
calculation that depends on the detected window.

## Confirmed gaps, not yet fixed

Ordered by what actually bites this deployment.

### 1. OpenClaw pins `maxTokens: 4096` on every model row — CRITICAL

Written by the custom-provider onboarding wizard, not chosen by anyone.
Docs: the default for a model with no authored cap is 32768; *"onboarding
saved 4096 (custom-provider wizard)"*.

Worse than the Hermes bug it resembles: Hermes sent *no* cap and hit a
silent server default. OpenClaw **sends 4096 explicitly**, so it
self-imposes a limit the endpoint does not require — measured 2026-11-09,
a request asking for 8000 completes.

Every long reply truncates at 4096 with no error. It also bounds the
compaction summary allowance, reproducing the Hermes failure by another
route.

Note: `openclaw doctor --lint --only core/doctor/legacy-output-cap`
returns "Unknown health check id" on 2026.11.1 — the check is documented
but not registered, so doctor will not catch this. Check it directly.

### 2. OpenClaw compaction runs on Opus with thinking on — CRITICAL

`compaction.model` unset (so: the session model, Opus) and
`thinkingLevel: "low"`. Docs warn the summary allowance can be spent on
reasoning tokens, and that a rejected summary leaves history uncompacted.
With `mode: "safeguard"`, the user is then warned **even when
`notifyUser` is false** — the Hermes chat-spam loop, reproduced.

Fix all three together: drop the 4096 cap, set `compaction.model` to the
flash model, set `thinkingLevel: "off"`.

### 3. `sessions.auto_prune` unset on Hermes — CRITICAL

Docs: *"Without pruning, `state.db` grows without bound — multi-GB files
within weeks were reported on gateway + cron installs."* That is exactly
this deployment, on a VM with a finite disk. First symptom reaching the
user is the bot spontaneously asking about disk pruning over Telegram,
which reads as a malfunction. Only *ended* sessions are pruned.

### 4. OpenClaw memory indexing is silently dead — SHOULD-FIX

`memory.search.provider` unset defaults to OpenAI embeddings; no key
exists. Doctor's own words: *"memory sync stops ... new and changed memory
files are not indexed."* The `session-memory` hook **is** enabled, so the
agent writes memory that is never indexed and appears, over weeks, to
forget things it was told. No error. Set `provider: "none"` for
keyword-only, then reindex.

### 5. Both agents run mechanical auxiliary work on Opus — SHOULD-FIX

Hermes `auxiliary.background_review.*` unset: a background fork replays
the conversation on the main model after turns. Docs put a cheap model at
3–5× lower cost with "memory capture identical". Same class as the
compression-model fix already made. `auxiliary.title_generation` and
`auxiliary.approval` likewise — the approval classifier runs on every
flagged shell command with a 30s budget.

### 6. Our endpoint is classified LAN, so four timeouts silently relaxed — SHOULD-FIX

`VM_BASE_URL` is `http://192.168.5.2:44497`. Hermes auto-detects
localhost/LAN endpoints and relaxes streaming timeouts: socket read 120s →
**1800s**, stale-stream detection 180s → 900s, non-streaming stale
detection **disabled**. Our proxy is not a slow local GPU — it is a shim
in front of a remote service. A wedged upstream hangs a Telegram turn for
up to 30 minutes instead of failing in 90 seconds. An explicit
`stale_timeout_seconds` is honoured even on local endpoints.

**This is the one nobody would have predicted**: a `192.168.x.x` address
silently changes four defaults and nothing in the config says so.

### 7. `cron.catch_up_missed` defaults true — SHOULD-FIX

After any VM suspend or gateway restart, every missed slot fires once on
return, each delivering to Telegram. A morning burst of stale briefs.

### 8. `unauthorized_dm_behavior` defaults to `pair` — SHOULD-FIX

An unknown Telegram user gets a one-time pairing code. Given that who may
message the bot is the *only* access control on an agent with shell access
and a mailbox, offering strangers a pairing affordance is the wrong
default. `ignore` drops silently.

### 9. Spec and reality disagree on OpenClaw's API shape — SHOULD-FIX

`spec/pi-target-state.md` says OpenClaw uses the Anthropic-shaped
`/v1/messages`. The live config has `api: "openai-completions"`. One of
them is wrong and several output-cap behaviours are adapter-specific.

### 10. `compression.idle_compact_after_seconds` is 0 — CONSIDER

Would compact a thread resumed after a gap, before the first reply. The
interesting part is second-order: in-place compaction *rebuilds the system
prompt*, which is where the `Current time:` line lives — so this may be
the one routine event that refreshes a stale clock. **Unverified
inference**, flagged by the audit as such. Worth testing, not worth
assuming.

### 11. Residue — CONSIDER

OpenClaw: a stale `agents.defaults.models` key naming `argo:gpt-4o`
(inert, but it is the exact id that silently ran both agents for weeks —
remove it before someone misreads it); 32 skills "allowed but
unavailable"; legacy auth rows not migrated.

Hermes: `curator` archives agent-written skills unused for 30 days;
bundled skills are exempt, so `google-workspace` is safe, but a skill the
agent writes for itself will quietly vanish.

## Examined and deemed reasonable

Recorded so the next audit need not re-derive them.

**Hermes:** log rotation (automatic, `RotatingFileHandler`);
`prompt_caching` (does not apply to our OpenAI-wire endpoint);
`database.journal_mode` (WAL correct here); `runtime.nofile_soft_limit`
and `malloc_arena_max` (already tuned for a long-running gateway);
`agent.max_turns: None` (a cap caused silent mid-task truncation);
`turn_liveness`, `session_stall_timeout`, `gateway_timeout`,
`reconnect_attention_after` (all enabled, sensibly sized for unattended
use); `tool_loop_guardrails` (hard stops already on for gateway and cron);
`security.redact_secrets` (on, and masks credential-shaped assignments);
`sessions.max_resume_messages` (far above any Telegram thread);
`compression.threshold` ratio floor (our absolute cap correctly wins).

**OpenClaw:** `proxy.proxyUrl` (correct, already checked by `verify.sh`);
`tools.web.fetch.useTrustedEnvProxy: true` (**non-obvious and right** —
without it `web_fetch` pins DNS locally and bypasses the proxy, and doctor
never enables it automatically); `agents.defaults.userTimezone` (set, and
now checked); Telegram `dmPolicy: allowlist` with a single allowed id and
the token as a SecretRef; `gateway.bind: loopback` with token auth;
`tailscale.mode: off`; `tools.profile: "full"` (deliberate — shell access
is the point); `contextPruning.mode: "off"`;
`maxActiveTranscriptBytes: 20mb`.

## Open questions

- Does OpenClaw rebuild its date/time line per turn or per session? The
  Hermes stale-clock bug came from a per-session prompt; the audit could
  not confirm OpenClaw's behaviour either way.
- What is `argo:claude-5-opus`'s real output ceiling through the proxy?
  8000 is confirmed to work; the upper bound is unmeasured.
- Is OpenClaw's `contextWindow: 128000` (another blanket wizard value)
  correct? Every compaction threshold is derived from it.

## Both vendors ship a doctor, and neither was being run

`hermes doctor` is now in `verify.sh`. `openclaw doctor` must be added
**with `--lint --all`**: the default run selects 39 of 69 checks and
reported `ok:true, findings:[]` while `--all` found 33. A bare
`openclaw doctor` in the suite would be a false green.

Both need output parsing rather than exit codes: `hermes doctor` exits 1
whenever any optional integration is unconfigured, and `openclaw doctor`
exits 0 even when `ok:false`.
