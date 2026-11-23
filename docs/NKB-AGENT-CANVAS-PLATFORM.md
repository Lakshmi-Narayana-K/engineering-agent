# NKB Agent Canvas — Platform Overview

Metrics, features, outcomes, and technical implementation for the **NKB Agent Canvas POC**
(`nkb-agent-canvas-poc`): a browser-hosted investigation workspace that runs **Cursor** over
the **Agent Client Protocol (ACP)** via **OpenHands Agent Canvas**, with layered security and
optional **production read** paths for shared engineering use.

---

## 1. Purpose and outcomes

### 1.1 What problem this solves

Engineering questions about NKB often span **multiple repositories**, **AWS**, **security
tools**, **spreadsheets**, and sometimes **production database rows**. Answers need **evidence
from code and live state**, not guesses. Non-developers and developers alike benefit from a
single chat surface that:

- Searches and reads many codebases with consistent rules.
- Cites paths and symbols.
- Uses governed MCP tools instead of ad-hoc credentials on laptops.
- Keeps **product Git checkouts** from being modified by the agent.

### 1.2 Intended outcomes

| Outcome | How the POC delivers it |
| --- | --- |
| **Evidence-backed answers** | `AGENTS.md`, `context/`, `knowledge/`, and `.cursor/rules/` steer investigation; agent is instructed to cite `repos/<repo>/...`. |
| **Cross-repo clarity** | Six linked product repos (three Django libraries + composition root, Drops, learner web UI) in one workspace. |
| **Safe local investigation** | Clean export strips secrets; sandbox container; ACP policy proxy; Git baseline verification. |
| **Shared LAN investigation (host)** | `start-local-shared.sh`: VPN + prod **reader** RDS, DBHub SQL, Django ORM via host worker, MCP gateways for AWS / Rapid7 / Sheets. |
| **Operability** | `bootstrap`, `start`, `stop`, `status`, smoke test, evaluation question bank. |
| **Auditability** | ACP permission decisions logged; ToolHive audit on MCP gateways. |

### 1.3 What this is not

- Not a deployment pipeline, PR bot, or write path to production data.
- Not a replacement for Cursor IDE on a developer machine (it **is** Cursor CLI in ACP mode,
  orchestrated by OpenHands).
- Not fully multi-tenant secure without further work (ToolHive uses synthetic identity locally;
  Cedar/OIDC deferred).

---

## 2. Key metrics

### 2.1 Workspace scale (clean export)

Figures from a representative export (`scripts/export-clean-source.sh`) after linking all repos.
**`node_modules`**, **`.venv`**, caches, and **46 credential/artifact patterns** in
`config/workspace-exclude.txt` are stripped before the agent sees source.

| Repository | Exported files | Export size | Role |
| --- | ---: | ---: | --- |
| `nkb_backend` | 2,235 | ~17 MB | Django composition root |
| `nkb_assessment_backend` | 10,505 | ~63 MB | Assessment / exam apps (pip library) |
| `nkb_learning_backend` | 13,589 | ~81 MB | Learning / content apps (pip library) |
| `ccbp-ide-drops-frontend` | 460 | ~8.3 MB | IDE Drops UI (CRA/craco) |
| `ccbp-ide-drops-infra` | 772 | ~85 MB | IDE Drops runtime / Docker infra |
| `kossip-web` | 16,127 | ~184 MB | Learner-facing web monorepo (Yarn/turbo) |
| **Total (approx.)** | **~43,700** | **~438 MB** | Six product trees + metadata |

Each export includes `_git-metadata.txt` (branch, HEAD, recent commit subjects) without a
`.git` directory inside the sandbox tree.

### 2.2 Evaluation and quality

| Metric | Value |
| --- | --- |
| Graded evaluation questions | **24** (`evaluations/questions.md`, groups A–E) |
| Typical narrow question latency (local code-only) | ~**20–40 s** (README observation; varies by model and breadth) |
| Exclusion patterns on export | **46** |
| Sandbox memory limit | **4 GB** |
| Sandbox `/tmp` tmpfs | **512 MB** |

### 2.3 Runtime ports and processes

| Port | Service |
| ---: | --- |
| **8100** | Agent Canvas UI (override: `NKB_POC_PORT`) |
| **18000** | Agent Server (Canvas-managed) |
| **18001** | Automation server (Canvas-managed) |
| **3001** | Canvas static frontend (`NKB_CANVAS_FRONTEND_PORT`) |
| **19103–19109** | ToolHive MCP gateway proxies (per server in `config/toolhive/servers.yaml`) |
| **19108** | DBHub (shared mode; host network for VPN → RDS reader) |

### 2.4 MCP surface (shared / ToolHive mode)

| Gateway | Proxy port | Enabled (typical) | Tools exposed (allowlisted) |
| --- | ---: | --- | --- |
| `aws-api` | 19106 | Yes | 5 (e.g. `aws___call_aws`, docs search) — **IAM is the boundary** |
| `rapid7-insightidr` | 19107 | Yes | 55 read-only-hint tools (derived from upstream annotations) |
| `google-sheets` | 19109 | Yes | 6 read-only sheet tools |
| `dbhub` | 19108 | Shared host (`start-local-shared`) | `execute_sql`, `list_resources` — **readonly + max_rows** |
| `aws-documentation` | 19103 | No (redundant with aws-api) | — |

### 2.5 Agent profiles (Cursor session mode)

| Profile | `acp_session_mode` | Shell / writes in Cursor |
| --- | --- | --- |
| `nkb-investigator-ask` | `ask` | No file-write tool; investigation via read/search |
| `nkb-investigator-agent` | `agent` | Shell + file writes in **sandbox** (`/workspace/generated`, etc.) |

Default on **`start-local-shared.sh`**: **`agent`** (`NKB_ACP_SESSION_MODE`). Plain **`start.sh`**
defaults to **`ask`**. Switch profile in Canvas; **start a new conversation** after switching
(mode is applied at ACP session creation).

---

## 3. Features

### 3.1 Operating modes

**Local investigator (`scripts/start.sh`)**

- Canvas on `http://localhost:8100`.
- Cursor ACP via custom shim chain.
- Product source from `workspace/repos` (read-only bind mount).
- No prod DB unless you extend the stack yourself.
- Smoke test optional.

**Shared local host (`scripts/start-local-shared.sh`)**

- Everything in local mode, plus:
  - Sources `repos/nkb_backend/env_prod.sh` (VPN expected).
  - Validates **RDS reader** hostname pattern when possible.
  - Stages **AWS credentials** for ToolHive profile `nkb-agent-alpha`.
  - Starts **DBHub** against prod MySQL reader (read-only tool config).
  - Starts **django-prod-host-worker** + **`django-prod-shell`** in sandbox (ORM like dev).
  - Publishes sandbox **`workspace/agent-state/mcp.json`** pointing at host gateways.
  - **`NKB_CANVAS_PUBLIC=1`** and LAN URL + API key (`nkb-shared-local` by default).

### 3.2 Investigation intelligence (prompt + context)

- **`AGENTS.md`**: Cross-repo model (composed Django app, in-process imports, not HTTP between
  libs); read-only rules; prod dry-run script playbook; profile switching.
- **`.cursor/rules/`**: Safety, prod DB reads, dry-run scripts, styling (when relevant).
- **`context/system.yaml`** + **`context/services/*.yaml`**: Machine-readable ownership and
  entry points.
- **`knowledge/*.md`**: Human-readable flows, dependencies, gaps, unknowns.

### 3.3 Production read paths (shared mode only)

| Capability | Entry | Boundary |
| --- | --- | --- |
| **Django ORM** | `django-prod-shell -f /workspace/generated/script.py` | Read-only DB user; host worker runs `manage.py shell` with Poetry venv; jobs queued from container |
| **SQL** | MCP `dbhub` → `execute_sql` | Reader endpoint, `readonly: true`, `max_rows: 1000` in DBHub config |
| **AWS** | MCP `aws-api` | IAM on `nkb-agent-alpha`; destructive ops denied at AWS |
| **Rapid7** | MCP `rapid7-insightidr` | Tool allowlist + read-only API key in Rapid7 |
| **Sheets** | MCP `google-sheets` | VIEWER share + `GSHEETS_READ_ONLY` + allowlist |

**Explicit non-goals:** Applying prod writes (`DRY_RUN=False` unlink scripts, migrations, etc.)
through this agent; raw `source env_prod.sh` in sandbox shell (blocked by policy; use wrapper).

### 3.4 Safety and integrity

- **Clean export** with post-export leak check (excluded patterns must not appear).
- **Git baseline** per repo; `verify-product-repos-untouched.sh` detects **new** changes only.
- **Docker sandbox**: read-only product tree, cap-drop, no-new-privileges, read-only root FS,
  dedicated `HOME` tmpfs, isolated Cursor state under `workspace/agent-state`.
- **ACP policy proxy**: command segmentation, MCP gating, sensitive path blocks, audit log.
- **Cursor compat proxy**: forwards ACP; renders `cursor/ask_question` and `cursor/create_plan`
  as chat text so Canvas does not hang.

### 3.5 Developer / operator UX

| Script | Purpose |
| --- | --- |
| `bootstrap.sh` | Prerequisites, symlinks, Git baseline |
| `export-clean-source.sh` | Build `workspace/repos` for sandbox |
| `start.sh` / `start-local-shared.sh` | Start stack (+ shared infra) |
| `stop.sh` | Stop POC processes (full or `--canvas-only`) |
| `status.sh` | Health, settings, active profile, repo dirty counts |
| `toolhive-up.sh` / `toolhive-install.sh` | MCP gateway lifecycle |

---

## 4. Technical implementation

### 4.1 Architecture (end-to-end)

```text
Browser (LAN or localhost)
        │
        ▼
OpenHands Agent Canvas          [@openhands/agent-canvas, npm global]
        │  HTTP + API key (shared mode)
        ▼
OpenHands Agent Server          [uvx, ports 18000/18001]
        │  spawns custom ACP command; JSON-RPC stdio
        ▼
runtime/acp-policy-proxy/       ENFORCED: permissions, audit, env scrub
        │
        ▼
runtime/cursor-compat-proxy/    cursor/* extensions → visible chat + valid JSON-RPC replies
        │
        ▼
scripts/agent-sandbox.sh        Docker: ro repos, generated/, MCP via host.docker.internal
        │
        ▼
Cursor CLI  `agent acp`         Subscription login; session mode from profile
        │
        ├── reads /workspace/repos/*  (exported source)
        ├── writes /workspace/generated (agent mode)
        ├── MCP → ToolHive gateways (host)
        └── django-prod-shell → queue → host worker (shared mode)
```

**Design choice:** OpenHands is **unmodified** upstream; integration is **`acp_server: custom`**
and a **replaceable shim chain**. Swapping Cursor for another ACP agent is primarily a change
to `acp_command` (`config/agent-engine.yaml`).

### 4.2 Repository wiring

Single source of truth for the repo set:

- **`scripts/_common.sh`**: `REPOS[]` and `REPO_SOURCES[]`.
- **`config/repos.yaml`**: Human manifest, baselines, documentation pointers.

Flow:

1. **`bootstrap.sh`**: `ln -sfn` → `repos/<name>`.
2. **`export-clean-source.sh`**: `git archive HEAD` + tar excludes → `workspace/repos/<name>`.
3. **`agent-sandbox.sh`**: bind-mount `workspace/repos` read-only at `/workspace/repos`.

Adding a repo requires updating `_common.sh`, `repos.yaml`, re-bootstrap, re-export, and
(optionally) `AGENTS.md` / `agent-engine.yaml` reachable paths.

### 4.3 ACP registration (Agent Server API)

`scripts/start.sh` after Canvas is healthy:

1. **`PATCH /api/settings`** — `agent_settings_diff`: `agent_kind: acp`, custom command
   pointing at policy proxy, `acp_session_mode` from `NKB_ACP_SESSION_MODE`.
2. **`POST /api/agent-profiles/nkb-investigator-{ask,agent}`** — two profiles, same shim,
   different session modes.
3. **`POST .../activate`** — activates profile matching env default.

Cursor subprocess chain (env):

```text
NKB_AGENT_COMMAND=scripts/agent-sandbox.sh
  → docker run ... node runtime/acp-policy-proxy/index.mjs acp
      → node runtime/cursor-compat-proxy/index.mjs acp
          → agent acp   (inside container)
```

### 4.4 ACP policy proxy (security-critical)

**File:** `runtime/acp-policy-proxy/index.mjs`  
**Policy:** `config/acp-permissions.json` (+ ToolHive server lists in YAML for MCP admission)

Responsibilities:

- Intercept **`session/request_permission`** (Cursor delegates gating to client in ACP mode).
- Allow/deny **shell segments**, **MCP tool calls**, parsed **AWS** operations, **SQL** keywords.
- Block reads of **sensitive paths** (e.g. `env_prod`, credential filenames) even when “read”
  tools are used.
- **Scrub** ambient AWS env vars; inject scoped credentials file for alpha profile when configured.
- Append decisions to **`runtime/logs/acp-permissions.jsonl`**.

Fail-closed on missing or invalid policy.

### 4.5 Cursor compatibility proxy

**File:** `runtime/cursor-compat-proxy/index.mjs`

- Relays standard ACP messages.
- Handles blocking **`cursor/ask_question`** and **`cursor/create_plan`** by emitting assistant
  text to Canvas and returning schema-valid responses so the turn completes.
- Optional thought-chunk buffering for readable “Thinking” sections in the transcript.

### 4.6 Sandbox container

**File:** `scripts/agent-sandbox.sh`  
**Image:** `nkb-agent-runtime:2026.08.11-e8db854` (configurable via `NKB_AGENT_IMAGE`)

| Mount / resource | Access | Purpose |
| --- | --- | --- |
| `workspace/repos` | ro | Product source |
| `workspace/generated` | rw | Scripts, query output |
| `context/`, `knowledge/`, `AGENTS.md` | ro | Investigation context |
| `workspace/agent-state` → `~/.cursor` | rw | MCP config, CLI state (isolated from developer HOME) |
| `/tmp`, `/home/agent` | tmpfs | Scratch; session writable HOME |
| Prod django mounts (flag file) | ro + job dir rw | `prod-django.env`, venv, `django-prod-shell`, job queue |

Network: **`host.docker.internal:host-gateway`** so MCP URLs in `agent-state/mcp.json` reach
ToolHive on the host.

### 4.7 Django prod shell (shared mode)

**Components:**

- `runtime/.prod-django-shell-enabled` — sentinel created by `start-local-shared.sh`.
- `runtime/prod-django-env.path` — absolute path to `env_prod.sh` (not mounted under that name
  in container to avoid ACP false positives).
- `runtime/django-prod-shell/django-prod-shell.sh` — in-container wrapper; queues job to host.
- `scripts/django-prod-host-worker.sh` — host loop: `runtime/django-jobs/*.req`, maps
  `/workspace/...` paths to POC workspace paths, runs Poetry venv Python + `manage.py shell`.

**wtq:** ORM runs on **host** with VPN; sandbox only submits jobs and prints stdout.

### 4.8 ToolHive and DBHub (shared mode)

- **`scripts/toolhive-up.sh`**: Starts enabled servers from `config/toolhive/servers.yaml` on
  loopback proxies; secrets via ToolHive environment provider.
- **DBHub** (`bytebase/dbhub`): Separate `thv run` with **`--network host`** so MySQL reaches
  RDS over VPN; password via `TOOLHIVE_SECRET_DB_PASSWORD`; permission profile pins egress to
  RDS host:3306.

Sandbox MCP config is regenerated to:

```json
{ "mcpServers": { "aws-api": { "url": "http://host.docker.internal:19106/mcp" }, ... } }
```

**`approve_sandbox_mcp_servers`** (`scripts/_common.sh`): stages HOME so `agent mcp enable`
approves servers for the **sandbox** Cursor identity, not the developer’s global IDE config.

### 4.9 Configuration map

| Path | Role |
| --- | --- |
| `config/agent-engine.yaml` | Documented engine settings template |
| `config/acp-permissions.json` | Shim allow/deny rules |
| `config/toolhive/servers.yaml` | MCP servers, ports, tool allowlists |
| `config/workspace-exclude.txt` | Export exclusions |
| `config/v0-policy.yaml` | Policy intent and review triggers |
| `config/repos.yaml` | Repo manifest and baselines |

### 4.10 Cursor session mode vs enforcement

| Layer | Enforced? | Notes |
| --- | --- | --- |
| ACP policy proxy | **Yes** | Primary control for shell/MCP/SQL/path reads in ACP mode |
| Cursor `ask` / `agent` | **Partial** | Ask removes write tool; **shell may still exist** — do not over-rely on ask alone |
| Docker sandbox | **Yes** | Filesystem and network reachability |
| IAM / RDS reader / API keys | **Yes** | External boundaries for live data |
| `AGENTS.md` / rules | Advisory | Shapes behavior |

---

## 5. Typical workflows

### 5.1 First-time setup

```bash
./scripts/bootstrap.sh
./scripts/export-clean-source.sh
./scripts/start.sh                    # local
# or
./scripts/start-local-shared.sh       # VPN + prod reads + LAN share
```

### 5.2 Daily shared investigation

```bash
bash scripts/stop.sh && bash scripts/start-local-shared.sh
# Teammates: http://<host-lan-ip>:8100  API key: nkb-shared-local
./scripts/status.sh
```

### 5.3 Prod dry-run script (example pattern)

1. User or agent writes script with **`DRY_RUN = True`** under `/workspace/generated/`.
2. Agent runs: **`django-prod-shell -f /workspace/generated/script.py`**.
3. Report stdout (counts, rows that would change). **Never** set `DRY_RUN = False` on prod here.

### 5.4 Prove product repos unchanged

```bash
./scripts/verify-product-repos-untouched.sh
```

---

## 6. Dependencies and prerequisites

| Component | Requirement |
| --- | --- |
| Node.js | ≥ 22.12 |
| `@openhands/agent-canvas` | Global npm install |
| Cursor CLI | `agent acp`, `agent login` |
| `uv` | Agent Server via `uvx` |
| Docker | Sandbox + ToolHive workloads |
| ToolHive | `scripts/toolhive-install.sh` → `runtime/toolhive/bin/thv` |
| Shared mode | VPN, `env_prod.sh`, AWS profile, Rapid7/Sheets secrets as configured |

---

## 7. Known limitations and roadmap hooks

- **Mid-conversation session mode switch:** OpenHands sets mode at session start; switch profile
  and open a **new chat**. No `switch_acp_mode` API equivalent to `switch_acp_model` yet.
- **ToolHive identity:** Synthetic local user; OIDC + Cedar deferred for true multi-user authZ.
- **Repository size:** Large monorepos (e.g. `kossip-web`) increase search latency and token use.
- **README V0 diagram** still shows three repos; operational set is **six** — this document
  supersedes that count for planning.
- **Kernel-level ro bind** on host checkouts deferred (sudo / fstab operational cost).

---

## 8. Related files (quick index)

| Topic | Location |
| --- | --- |
| Operator README | `README.md` |
| Agent instructions | `AGENTS.md` |
| Repo manifest | `config/repos.yaml` |
| Enforcement detail | `knowledge/enforcement-model.md` |
| Evaluation | `evaluations/questions.md` |
| ACP probe | `runtime/cursor/acp-probe.mjs` |
| Smoke test | `runtime/smoke-test.py` |

---

*Document version: aligned with dual profiles, six-repo export, and `start-local-shared.sh`
prod-read stack as of POC development on the NKB engineering agent workspace.*
