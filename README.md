# NKB Agent Canvas POC (V0)

Ask a question in a browser; Cursor investigates three local NKB repositories and
answers with evidence. No repository is modified.

```text
Browser
   │
   ▼
OpenHands Agent Canvas            (upstream, unmodified)
   │
   ▼
OpenHands Agent Server            (upstream, unmodified)
   │  spawn + JSON-RPC over stdio
   ▼
runtime/acp-policy-proxy/         ← permission decisions, audit, fail-closed
   │                                  the only security-critical code we write
   ▼
runtime/cursor-compat-proxy/      ← cursor/* translation only (engine-specific)
   │
   ▼
scripts/agent-sandbox.sh          ← container boundary
   │
   ▼
cursor CLI `agent acp`            (ask mode: read-only, in the sandbox)
   │
   ▼
repos/nkb_backend · repos/nkb_assessment_backend · repos/nkb_learning_backend
```

## Quick start

```bash
./scripts/bootstrap.sh   # one-time: check prerequisites, link repos, capture Git baseline
./scripts/start.sh       # start the stack, register Cursor, run the smoke test
```

Then open **http://localhost:8100** and ask a question.

```bash
./scripts/status.sh                          # what is running, engine config, repo state
./scripts/stop.sh                            # stop only what this POC started
./scripts/verify-product-repos-untouched.sh  # prove the repos were not modified
```

To restart from scratch: `./scripts/stop.sh && ./scripts/start.sh`

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Node ≥ 22.12 | required by `@openhands/agent-canvas` |
| `@openhands/agent-canvas` | `npm install -g @openhands/agent-canvas` |
| Cursor CLI with ACP | `agent acp --help` must succeed |
| Cursor login | `agent login` — the ACP subprocess inherits it |
| `uv` | Agent Canvas uses `uvx` to run Agent Server |

No Cursor API key is needed. Agent Server runs on this machine, so the ACP
subprocess picks up your existing CLI login, and a subscription login takes
priority over an API key anyway.

## Ports

| Port | Process | Notes |
| --- | --- | --- |
| 8100 | Agent Canvas ingress (the UI) | upstream default is 8000; changed because 8000 is taken |
| 18000 | Agent Server | started by Agent Canvas |
| 18001 | Automation server | started by Agent Canvas |
| 8000 | **not ours** — a developer's Django `runserver` | never touched by these scripts |

Override with `NKB_POC_PORT=<port> ./scripts/start.sh`.

## Layout

```text
AGENTS.md                  cross-repo instructions Cursor reads on every conversation
.cursor/rules/             always-applied safety and investigation rules
repos/                     symlinks to the three real checkouts (read-only)
config/                    repos, engine, and policy configuration
context/                   machine-readable service + system metadata
knowledge/                 generated human-readable findings, with evidence
runtime/acp-policy-proxy/  permission decisions, audit, fail-closed
runtime/cursor-compat-proxy/  cursor/* -> Canvas translation
runtime/acp-proxy/         shared transparent relay used by both
runtime/cursor/            raw ACP probe, Git baselines
runtime/smoke-test.py      end-to-end test through Agent Server
scripts/                   bootstrap, start, stop, status, integrity verification
evaluations/               question set, grading format, results
```

## How the integration works

OpenHands Agent Server ships a full ACP *client*: it spawns an external agent CLI as
a subprocess and relays each conversation turn over JSON-RPC on stdio. Cursor is not
one of its built-in providers (Claude Code, Codex, Gemini CLI are), but `acp_server:
"custom"` is a first-class option that accepts any launch command.

So the wiring is configuration, not code:

```yaml
agent_kind: acp
acp_server: custom
acp_command: [node, <poc>/runtime/acp-policy-proxy/index.mjs, acp]
acp_session_mode: ask
```

`scripts/start.sh` applies this via `PATCH /api/settings`. The same thing is
reachable in the UI under **Settings → Agent → Preset → Custom**.

### Why there is a shim

Cursor sends extension methods that standard ACP does not define. Two of them —
`cursor/ask_question` and `cursor/create_plan` — are **blocking**: the agent waits
for a JSON-RPC response before continuing.

Agent Server answers unknown extension methods with an empty `{}` (its
`ACPClient.ext_method` returns `{}`). That prevents a hang, but the payload never
reaches the browser — so a clarifying question from Cursor would be silently
swallowed.

`runtime/cursor-compat-proxy/index.mjs` sits between the two and does the minimum:

- forwards all standard ACP traffic byte-for-byte
- intercepts `cursor/*` methods, renders their payload as a normal
  `agent_message_chunk` so Canvas displays it as ordinary assistant text
- replies to Cursor with a schema-valid response so the turn continues

That is its entire job. It contains no agent loop, no LLM integration, no code
search, and no terminal parsing — Cursor provides all of that.

Verified: with the shim, a plan-mode prompt that triggers `cursor/create_plan`
completes normally and the plan text appears in the transcript.

## Safety model

`repos/**` is read-only. Protection is layered, and the layers are not equally strong:

| Control | Strength |
| --- | --- |
| Cursor `ask` session mode — no file-write tool, no shell tool | **enforced** by the CLI |
| `repos/` as symlinks, originals stay source of truth | structural |
| `AGENTS.md` + `.cursor/rules/00-v0-safety.mdc` | advisory (prompt) |
| Git baseline + `verify-product-repos-untouched.sh` | detective (after the fact) |

The strongest control is the session mode: ask mode has no tool capable of writing a
file. Do not change `acp_session_mode` to `agent` — that reintroduces write access.
`plan` is an acceptable alternative if questions start needing `git log` or `rg`.

There is no AWS, database, or product-service network access, and no credentials are
wired into the agent process.

### MCP servers are off

Cursor CLI in ACP mode loads the **user-level** `~/.cursor/mcp.json` no matter which
workspace it runs in. On this machine that config launches a Rapid7 InsightIDR MCP
server holding a live API key — a production security tool, explicitly out of scope
for V0. A project-level `.cursor/mcp.json` with an empty `mcpServers` map was tested
and **does not** override it.

The fix that works is the CLI's own approved-list:

```bash
agent mcp disable insightidr    # applied; reverse with `agent mcp enable insightidr`
```

Verified by process ancestry: before, InsightIDR ran as a descendant of the ACP
subprocess; after, it does not. The Cursor IDE keeps its own MCP servers and is
unaffected. Nothing was ever queried — the server was only being spawned — but its
tools were reachable, which is what mattered.

Adding any MCP server to this workspace is a policy review trigger.

All three repositories were **already dirty** when the baseline was captured. The
verification script asserts *nothing new changed*, not that the repos are clean.

## Known limitations

- **Write protection is advisory plus detective, not preventive.** Ask mode removes
  the write tool, which is strong, but a mode change would remove that. Kernel-level
  read-only bind mounts were considered and deferred: they need `sudo` and do not
  survive a reboot without an `fstab` entry.
- **Agent Server runs `git init` on the workspace root.** This POC directory is
  therefore a Git repository whether or not you wanted one. `.gitignore` keeps
  `repos/` and runtime state out of it. This is also why the workspace root is a
  wrapper directory and not a product repo — pointing Agent Server at a product
  checkout would let it do Git work there.
- **Cursor's multiple-choice questions render as plain text.** The shim converts
  `cursor/ask_question` into a text message; answer in chat as normal prose.
- **`acp_model` is left unset.** Model selection for a `custom` provider is not
  reliably applied, so Cursor uses its own default.
- **The ACP subprocess inherits your full user permissions.** It is not sandboxed
  from the rest of the filesystem; only the session mode constrains it.
- **Repository size.** 2.1 GB across three repos, so broad questions take longer.
  Narrow questions answer in roughly 20–40 seconds.

## Swapping the engine

Replacing Cursor with another ACP agent is a change to `acp_command` only. Agent
Canvas and Agent Server are untouched, which is the point of putting the boundary at
ACP. `config/agent-engine.yaml` lists the launch commands for Claude Code, Codex, and
Gemini CLI.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Stack will not start | `runtime/logs/agent-canvas.log`; is 8100 free? |
| Smoke test fails | `runtime/logs/smoke-test.log`, then isolate Cursor with `node runtime/cursor/acp-probe.mjs --cwd "$PWD"` |
| Conversation hangs | Trace the shim: `NKB_ACP_SHIM_LOG=/tmp/shim.jsonl`, then look for an unanswered `cursor/*` request |
| Answers cite the wrong repo | Check `context/system.yaml` and `knowledge/cross-repo-dependencies.md` are present and accurate |
| Not logged in | `agent login`, then restart the stack |
