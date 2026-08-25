# NKB System Overview

Generated 2026-08-25 from static source reading of three local repositories. No AWS,
database, or network access was used. Every claim below carries a source path.

## The shape of the system

The single most important structural fact, and the one most likely to be gotten wrong:

**These are not three network-separated services. They are one composed Django
application plus two libraries.**

- `nkb_backend` is the **composition root** and the deployable. It owns the settings
  modules, the root URLconf, the database configuration, and every deployment entry
  point — HTTP, WebSocket, EventBridge, SQS, cron, ECS, and a Bedrock AgentCore
  gateway.
- `nkb_assessment_backend` and `nkb_learning_backend` are **libraries of Django apps**.
  Each publishes its apps as pip packages to a private CodeArtifact index, and
  `nkb_backend` installs them.

The evidence is direct and mutually reinforcing:

- `nkb_backend/pyproject.toml:39-40` declares `nkb-learning-backend 5.40.11` and
  `nkb_assessment_backend 5.31.4` as dependencies.
- `nkb_backend/zappa_settings.json:160-163` is the *only* place the four non-HTTP
  Lambda handlers are wired.
- `nkb_learning_backend/env_beta.sh:1,11,51` — the learning repo's own environment
  script — sets `DJANGO_SETTINGS_MODULE=nkb_backend.settings.ccbp_beta` and
  `function=nkb-backend-ccbp-beta`. The library repo's beta environment points at the
  host.
- `nkb_learning_path/docs/nkb_backend_integration.md:3` says it outright:
  `nkb_learning_path` is "an app package installed in `nkb_backend`".

### Why this is easy to get wrong

Both library repos carry a full `zappa_settings.json` with alpha/beta/gamma/prod
stages, their own `manage.py`, their own `urls.py`, and their own settings package.
Each *looks* like an independently deployable service. Whether those legacy standalone
deployments are still live is genuinely UNKNOWN. But the composed deployment is
unambiguous, and it is the one the environment scripts target.

### The consequence that matters

Because the three repos share a process, cross-repository calls are **ordinary Python
function calls**. There is no serialization, no transport, no base URL, no retry
policy, no timeout, and no independent failure mode. A "call from learning into
assessment" is `from nkb_exam.interfaces.service_interface import ServiceInterface`
followed by a method call.

There is exactly **one** genuinely asynchronous cross-repo edge in the entire system:
the CompilerBox code-evaluation round trip over SQS. See
[cross-repo-dependencies.md](cross-repo-dependencies.md).

## What each repository owns

| Repository | Role | Domain |
| --- | --- | --- |
| `nkb_backend` | Composition root, deployable | Settings, routing, deployment entry points, AI coach (Bedrock), content MCP, bulk content loading, gamification wrapper, ops |
| `nkb_assessment_backend` | Library (19 apps) | Questions, exams, assessments, attempts, coding practice, contests, quizzes, certificates, plagiarism, leaderboard |
| `nkb_learning_backend` | Library (30 apps) | Content tree, courses, cohorts, learning paths, learner progress, auth and onboarding, discussions, IDE tooling, NIAT |

`nkb_backend`'s public HTTP surface is the **union** of all three repos' routes,
because `nkb_backend/urls.py:37-44` builds `/api/<app_name>/` from `INSTALLED_APPS`.
An endpoint served by `nkb_backend` may be implemented entirely in a sibling repo.

## How a request is routed

None of the three repos hand-writes URL patterns. Each app ships an
`api_specs/api_spec.json` (Swagger 2.0), and `python manage.py build` — a
`django_swagger_utils` command — generates `<app>/build/urls.py` and validator classes
from it. `build/` is gitignored, so the generated routing is a build artifact, not
source.

The layered call path inside an app is consistent across all three repos:

```
views/<operation>/api_wrapper.py   # decorated, receives an authenticated principal
  -> interactors/                  # business logic, no ORM access
    -> storages/                   # interface + implementation, owns the ORM
      -> models/
  -> presenters/                   # response construction
  -> adapters/                     # cross-app and external calls
```

Two generations of the swagger tooling coexist. Older views import from
`django_swagger_utils.drf_server.utils.decorator`; newer ones from
`dsu.dsu_gen.openapi.decorator`. Both appear in `nkb_learning_backend`.

## Authentication

`AUTH_USER_MODEL` is `ib_users.UserAccount` — owned by an external shared package, not
by any of these three repos (`nkb_backend/settings/base_swagger_utils.py:161`).

DRF is configured permissively at the framework level (`DEFAULT_PERMISSION_CLASSES` is
`AllowAny`). Enforcement is per-endpoint, driven by the `security` block in each
`api_spec.json` plus the validate decorator. Views receive an already-authenticated
principal as `kwargs['user'].user_id` and perform no auth checks of their own.

A separate `X-API-KEY` path exists for service-to-service calls.

`nkb_learning_backend` has two auth apps and both are live. `nkb_auth_v2` is current
(OAuth authorization-code exchange); `nkb_auth` is legacy (password/OTP) but is *not*
dead — it still owns `UserRole`, feature flags, Mattermost linkage, and
user-extra-details storage that `nkb_auth_v2`'s own login view imports. Both expose
`login_v1` simultaneously.

## Data

There is no per-app database routing. `nkb_backend/db_router.py:8-25` defines no
routing rules and `allow_relation` always returns `True`. In the composed deployment
all three repos share one relational database.

Whether that database is PostgreSQL or MySQL is UNKNOWN from source: `RDS_DB_ENGINE`
is env-supplied, both drivers are declared, and both a Postgres and a MySQL CI harness
script exist. `nkb_learning_backend/env_beta.sh` sets MySQL for beta.

DynamoDB is used narrowly — in `nkb_learning_backend` for exactly one model,
`UserResourceProgressLog`.

## Async and background work

There is **no Celery** anywhere. The async primitives are:

- **Zappa async Lambda tasks** — `zappa.asynchronous.task` re-invokes the same Lambda.
- **AWS Step Functions** — used as a delayed-execution scheduler; callers
  `start_execution` with a `lambda_payload` containing a dotted command path and an
  `alarm_datetime`.
- **SQS** — only for the CompilerBox evaluation round trip.
- **ib_events** — a pub/sub layer whose transport is implemented inside the
  third-party `ib_events` package. `EVENT_BUS_ARN` values point toward EventBridge but
  no first-party code confirms it.
- **ECS Fargate** — for AI project-submission evaluation.

`nkb_learning_backend` has no SQS producer or consumer at all.

## Known structural risks

1. **Undeclared cyclic dependency.** `nkb_assessment_backend` imports
   `nkb_learning_backend` apps but does not declare the dependency in its
   `pyproject.toml`. The imports are deferred inside property and method bodies, so
   the package installs and imports cleanly standalone — failures surface only at call
   time, in the composed deployment.

2. **App name collision.** A top-level `nkb_coach` app exists in *both* `nkb_backend`
   and `nkb_learning_backend`. `nkb_backend` registers its own; learning's `APPS` list
   omits it. Which one wins on `sys.path` is not determinable from source.

3. **Version pins disagree.** `nkb_backend/pyproject.toml` pins sibling packages at
   5.x while `nkb_backend/requirements_project.txt` pins them at 3.x — two major
   versions apart. The same split exists in `nkb_learning_backend`.

4. **Runtime version disagreement.** Dockerfiles and Zappa configs say Python 3.7;
   `pyproject.toml` files say `^3.12` with Django 5.1.

5. **Committed credentials.** `nkb_learning_backend/env_beta.sh` is tracked in Git and
   contains live-looking credential *values* — AWS access keys, an RDS password, a
   Django `SECRET_KEY`, and an OpenAI token. `.gitignore` carries an `env_*` rule, so
   the file appears to predate it or to have been force-added. No value was read out,
   copied, or validated. This should be triaged by a human.

## Reading order for a new question

1. This document, for shape.
2. [cross-repo-dependencies.md](cross-repo-dependencies.md) — before claiming *any*
   interaction between repos.
3. The relevant `context/services/*.yaml` for module ownership.
4. [documentation-gaps.md](documentation-gaps.md) — before trusting any
   `project_docs/` file.
5. The source itself. Docs are hints; code is the authority.
