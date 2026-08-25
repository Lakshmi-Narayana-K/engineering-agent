# Unknowns

Questions this analysis could **not** answer from local source alone. When a user asks
something that lands here, say so and name what evidence would settle it — do not guess.

## Deployment and topology

**Are the legacy standalone deployments of the two library repos still live?**
Both `nkb_assessment_backend` and `nkb_learning_backend` ship a full
`zappa_settings.json` with alpha/beta/gamma/prod stages, yet `env_beta.sh` in the
learning repo targets `nkb-backend-ccbp-beta`. Both artifacts are present and current.
*Would settle it:* the AWS Lambda function inventory, or the CI/CD pipeline definition.

**Does production run PostgreSQL or MySQL?**
`RDS_DB_ENGINE` is env-supplied. Both `psycopg2` and `mysqlclient` are declared, both
`codeship_pg_tests.sh` and `codeship_mysql_tests.sh` exist, and the code default is
Postgres while `env_beta.sh` sets MySQL.
*Would settle it:* the deployed environment variables, or the RDS instance type.

**Do the standalone deployments share the composed deployment's database?**
All three repos read identical `RDS_*` variable names, and there is no per-app DB
routing. In the composed deployment a single shared database is certain. Across
deployments it is unknown, because the values are deploy-time secrets.

**What is the authoritative Python and Django runtime?**
Dockerfiles and Zappa configs say Python 3.7. Every `pyproject.toml` says `^3.12` with
Django 5.1. Both are checked in and neither is marked stale.

**How are 80 of the 83 `nkb_backend` Lambda cron schedules provisioned?**
`zappa_settings.json` has no `events` block, and `add_cron_job_events.py` covers only
three schedules for one hardcoded stage.
*Would settle it:* the EventBridge rule inventory, or an infrastructure-as-code repo
outside these three.

## Packaging

**Which installed distribution provides each of the ~35 third-party swagger apps?**
Many apps in `INSTALLED_APPS` are not named in any `pyproject.toml`. Resolving them
requires reading `.venv/site-packages`, which was outside the scope of this
source-only analysis.

This affects several adapters in `nkb_learning_backend` — `nkb_exam`, `nkb_question`,
`nkb_certificate`, `nkb_coding_contest`, `nkb_coding_practice`,
`nkb_adaptive_video_question`, `nkb_plagiarism`, `nkb_exam_extensions`, `nkb_groups`,
`nw_connect`, `nw_events`, `nw_clubs` — which are imported via `service_interface` but
appear in no dependency declaration. They are presumably apps of `nkb_backend` or
transitive packages, but the origin repository is UNKNOWN.

**Which `nkb_coach` wins?**
A top-level `nkb_coach` app exists in both `nkb_backend` (registered) and
`nkb_learning_backend` (unregistered, and containing zero `.py` files). Which resolves
on `sys.path` in the composed deployment is not determinable from source.

## Events and messaging

**What transport backs `ib_events` `@register` subscriptions?**
EventBridge, SNS+SQS, or in-process dispatch — the implementation lives inside the
third-party `ib_events` package. `EVENT_BUS_ARN` values point toward EventBridge but no
first-party code confirms it.

**Who produces the `POSTER_GENERATED` event?**
An external rendering service, outside all three repositories. All three repos are
co-subscribers.

**Where are the receivers for `end_exam_sender` and the two Woolf signals?**
Not found in any of the three repositories. Either external, or dead.

## Application behaviour

**Where is the generic "mark unit complete" HTTP endpoint?**
Not present in `nkb_learning_backend/nkb_resources/views/`, which holds only two read
endpoints. Writes arrive via ib_events, via `interfaces/service_interface.py`, or from
`nkb_interactive_video` / `nkb_learning_resource`. It may live in `nkb_backend`, or all
writes may flow through events and service interfaces.

**How are `nkb_niat.AssessmentAttempt` rows created?**
`nkb_niat/interactors/create_user_assessment_attempt_details.py` exists but its caller
was not traced.

**Which auth app do clients actually use?**
`nkb_auth` and `nkb_auth_v2` both expose `login_v1` and `refresh_auth_tokens_v1`
simultaneously at different paths. Their coexistence is certain; client routing is not
determinable from these repos.

**What is the caching topology?**
`nkb_learning_backend` has no `CACHES` setting despite one cacheops call site and a
documentation claim of Redis. The configuration lives in the host project or an external
package.

## Artifacts not read

**Generated `build/` directories.** Gitignored build artifacts. The exact URL regex per
`operationId` is inferred from `urls.py` plus `api_spec.json` rather than read directly.

**Working-tree state.** All three repos were dirty at baseline (12, 17, and 24 changed
entries respectively). In `nkb_learning_backend` the untracked files include 15
scaffolded `create_todo`/`get_todo`/`update_todo`/`delete_todo` view directories across
three apps, plus a triple-duplicated `end_datetime` field in
`nkb_collective_learning/models/models.py:16-18`. Whether these are intentional
work-in-progress or tooling artifacts is unknown. Nothing was touched.

---

## How to answer when a question lands here

State the unknown plainly, give whatever partial evidence exists, and name the artifact
that would resolve it. For example:

> I can't confirm whether production is Postgres or MySQL from source. `RDS_DB_ENGINE`
> is supplied by the environment, the code default is
> `django.db.backends.postgresql_psycopg2`
> (`nkb_learning_backend/settings/base_pg_db.py:8-21`), but `env_beta.sh:15-16` sets
> MySQL for beta and `mysqlclient` is the only driver in the poetry `db` group. The
> deployed environment variables would settle it.

Do not convert a MEDIUM-confidence inference into a HIGH-confidence claim to make an
answer feel complete.
