# nkb_backend — navigation profile

Structured metadata: [`context/services/nkb_backend.yaml`](../../context/services/nkb_backend.yaml)

## What it is

The composition root and the only deployable. It contains very little domain logic of its
own; its job is to assemble roughly ninety Django apps — a handful first-party, the rest
installed from the sibling repos and internal pip packages — into one runtime, and to own
every way the outside world gets in.

If you are looking for *where something is configured, deployed, scheduled, or wired*,
it is here. If you are looking for *what something does*, it is usually in a sibling.

## Where to look first

| Question | File |
| --- | --- |
| What apps exist / what is the API surface | `nkb_backend/settings/base_swagger_utils.py`, `nkb_backend/urls.py:37-44` |
| How is anything deployed | `zappa_settings.json` (esp. `:160-163`) |
| What runs on a schedule | 83 declared cron jobs — but see the unknown below |
| How does async command dispatch work | `zappa_command_receiver.py` |
| How do CompilerBox results come back | `sqs_lambda_handler.py:19-26` |
| Database configuration and routing | `nkb_backend/settings/base*.py`, `db_router.py:8-25` |
| Queue names, event bus ARNs, external URLs | `nkb_backend/settings/ccbp_prod.py`, `base_server.py` |

## First-party apps worth knowing

- **`nkb_core`** — shared platform primitives. `nkb_learning_backend` imports
  `nkb_core.app_interfaces.service_interface` directly.
- **`nkb_load_data`** — bulk content loading from Google Sheets into both siblings'
  models, in-process. Also owns the ECS Fargate task launcher that
  `nkb_learning_backend/nkb_projects` reaches into.
- **`nkb_coach`** — AI learning coach on Bedrock. **Name collides** with a (dead)
  `nkb_coach` directory in `nkb_learning_backend`.
- **`nkb_content_mcp`** — MCP server surface over platform content.
- **`nkb_gamification_wrapper`** — wrapper over external gamification packages.

## Traps

**No `project_docs/`.** This is the least documented repo in the set despite being the
only one that actually deploys. Source is the sole authority for anything here.

**`pyproject.toml` and `requirements_project.txt` disagree by two major versions** on the
sibling package pins (5.x vs 3.x). Neither is marked stale.

**The API surface is not this repo's code.** `urls.py` builds routes from
`INSTALLED_APPS`, so an endpoint served by `nkb_backend` is frequently implemented
entirely in `nkb_assessment_backend` or `nkb_learning_backend`. Grepping this repo for a
route handler will often find nothing.

**Cron provisioning is mostly invisible.** `zappa_settings.json` has no `events` block and
`add_cron_job_events.py` covers only three schedules for one hardcoded stage. How the
other eighty are provisioned is UNKNOWN from this repo.
