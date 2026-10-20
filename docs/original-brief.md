> **This is the original handoff brief**, written 2026-10-15, before anything
> existed. It was addressed to a coding agent — it says so in its own opening
> line, and it ends with a "Tasks for Claude Code" list. It was the repo's
> `README.md` until the build was finished.
>
> It is kept for the reasoning: why a VM rather than Docker, why Lima, why an
> egress allowlist, why no chat channel before verification. It is **not**
> instructions. For those:
>
> | You are | Read |
> |---|---|
> | a person who just cloned this | `README.md` |
> | a coding agent asked to build it | `CLAUDE.md` (= `AGENTS.md`) |
> | a coding agent on Linux / a DGX Spark | `docs/spark-handoff.md` first |
>
> Parts of it are now out of date. Its task list is done except items 5
> (failover test) and 6 (snapshot and porting docs); `todo.md` tracks the
> remainder. Its open questions were answered: Argo for models, Telegram as
> the channel, the agents on the Spark long term. Its description of an
> in-VM proxy is superseded — the model path now runs to a gateway on the
> host, see `README.md`.

---

# Handoff: Sandboxed agentic environment bootstrapped with Pi

Date: 2026-10-15
Purpose: carry the design discussion into Claude Code so it can build the pieces (VM config, Pi bootstrap spec, verification checks).

## Goal

Bootstrap an environment of persistent agents (OpenClaw, Hermes Agent, and similar) by installing Pi and having Pi set the others up. Do this inside a sandbox that protects the host machine from misbehaving agents. First trial on a MacBook (M5, 32 GB), later on a DGX Spark, and ultimately should work on any reasonably modern Linux machine.   

The basic environment needs to include access to models (local or remote), and a user should be able to install Pi and hand Pi this repository to set up a basic environment with:
1. An OpenClaw gateway and one agent
2. A Hermes gateway and one agent
3. Both agents with access to Telegram for communication with the user.

On the Mac we will use a virtual environment using Lima for the entire install (including Pi).

## Other Important Guidelines

Eventually this repo will be public, so local setup such as agent names, tokens, agent descriptions, etc. should be .gitignored.  For future users, example files for holding these values should be provided along with instructions on how to enter their specific details.

## Guidelines for the first attempt, using the MacBook

We will be using argo-proxy for model access (same access as Claude Code is using, described in ~/.claude/settings.argo.json

## What the tools are

- **Pi**: minimal open-source (MIT) coding agent harness by Mario Zechner, now owned by Earendil. Four core tools: Read, Write, Edit, Bash. Extends itself by writing its own tools and hot-reloading them. Deliberately has no MCP, no built-in sub-agents, and no permission prompts. Loads AGENTS.md (and CLAUDE.md) from the current and parent directories. Global config lives in ~/.pi/agent (credentials in auth.json, treat as a secret).
  - Install: npm install -g --ignore-scripts @earendil-works/pi-coding-agent (Node.js 22.19 or newer), or the installer script at https://pi.dev/install.sh
  - Use the @earendil-works package scope. The older @mariozechner scope is stale.
  - Run pi in a working directory, then use its login command to connect a subscription or API key.
- **OpenClaw**: personal-assistant gateway. It embeds Pi directly (imports Pi's AgentSession via createAgentSession) as its agent core, and adds the messaging Gateway, channels, and its own tools.
  - Install: curl -fsSL https://openclaw.ai/install.sh | bash
  - Onboard: openclaw onboard --non-interactive --gateway-auth token --install-daemon (the daemon flag registers a launchd or systemd user service)
  - Verify: openclaw gateway status, openclaw doctor
  - Gateway token can be stored as an env SecretRef instead of plaintext.
  - Gateway can be exposed through Tailscale serve.
- **Hermes Agent** (Nous Research): open-source self-hosted agent with persistent memory, self-written skills, and a messaging gateway.
  - Install: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
  - Then: hermes setup (pick provider, configure gateway), hermes doctor (verify), hermes (chat)
  - Migrating from OpenClaw: hermes claw migrate
  - State lives in ~/.hermes

Both installers are curl-to-bash. Have the agent fetch and show the script before running it, or pin a release.

## Decisions made so far

1. Models: remote primary models, plus a local fallback model served by vLLM on the DGX Spark (host spark-ts on the Tailscale network).
2. Isolation: a dedicated arm64 Linux VM for the agents. A VM is stronger than Docker because containers share the host kernel. The VM keeps systemd, so the OpenClaw daemon install works as documented.
3. DGX Spark layout (for later): GPU workloads (vLLM) in Docker with the NVIDIA runtime. Agents in a VM that needs no GPU and reaches vLLM over a private endpoint or Tailscale with a single port allowed. The Spark has 128 GB of unified memory shared by CPU and GPU, so a VM allocation (8 to 16 GB is plenty) comes out of the same pool as the model. Cap vLLM GPU memory utilization to leave host headroom, since vLLM memory exhaustion has frozen SSH sessions before.
4. MacBook trial: use Lima with a full Ubuntu arm64 guest.
   - Lima is a CNCF incubating project, the base for Colima, Rancher Desktop, and AWS Finch, and has explicit AI-agent hardening examples and an MCP server feature.
   - Give the VM about 8 GB and 4 cores. No local inference on the Mac.
   - Remove the default home-directory mount (set mounts to an empty list). At most one dedicated read-only share.
   - NAT networking. Install Tailscale inside the VM to reach the Spark's vLLM endpoint.
   - Restrict egress to the model providers and the Spark. A small forward proxy inside the VM is the cleaner way to allowlist domains.
   - Snapshot or clone the VM after a clean bootstrap, before enabling any chat channel.
   - Caveat: the VM sleeps when the Mac sleeps, so agents are not persistent in this trial.
5. Apple's native container tooling (the container CLI and Containerization framework, one lightweight VM per container, needs macOS 26) was considered. It is young, and containers there have no systemd by default, so the OpenClaw daemon path would not work as documented. Deferred. Revisit later for disposable per-agent isolation. Current feature status was not verified beyond mid-2025 coverage.

## Security requirements to bake into the setup

- Remote API keys and the vLLM key live only inside the VM. Use dedicated keys with spend caps and separate bot accounts for any chat channel, never personal accounts.
- Bind vLLM to the private or Tailscale interface only, with an API key set.
- Use env SecretRefs or equivalent. Do not write plaintext tokens into configs or chat.
- No chat channels enabled until the bootstrap is verified. The agent must stop and summarize before enabling any channel.
- During failover to the local fallback model, agents should ask before destructive actions (smaller models with shell access are riskier).

## vLLM fallback requirements

- Tool calling must work: enable auto tool choice and the correct tool-call parser for the chosen model, and pick a model that is genuinely good at tool use.
- Context window must be large enough for the agents' system prompts and session history.
- Failover config syntax for each agent (OpenClaw provider failover, Hermes custom OpenAI-compatible endpoint, Pi custom provider) has not been verified. Check current docs.

## Tasks for Claude Code

1. Write a Lima YAML for an Ubuntu arm64 VM with: no mounts, 4 CPUs, 8 GB memory, NAT networking, provisioning that installs Node 22.19 or newer, Tailscale, and a forward proxy with a domain allowlist.
2. Write an AGENTS.md spec for Pi describing the target state: Pi installed, OpenClaw and Hermes installed and running as services, state directories, providers (remote primary, vLLM fallback), secrets handling, and the stop-and-summarize checkpoint before channels.
3. Have the spec require Pi to produce an idempotent setup script (not ad hoc commands) so the bootstrap is repeatable on another machine.
4. Write automated verification: gateway status and doctor checks for OpenClaw, hermes doctor, reboot persistence, and egress allowlist tests (confirm a non-allowed destination is blocked).
5. Write a failover test: block the remote provider from inside the VM, then confirm each agent switches to the vLLM endpoint and completes a task that uses tools.
6. Document how to snapshot and restore the VM, and how to later move the same spec to the Spark or a VPS.

## Open questions

- Which remote model providers and which fallback model on the Spark?
- Which channels (if any) get enabled after verification?
- Whether to keep the agents on the MacBook long term or move them to the Spark or a VPS for always-on use.
