# Documentation Gaps

Places where `project_docs/` and other checked-in documentation **disagree with the
source**, or where documentation is absent. Every entry was verified by reading both.

**Operating rule: `project_docs/` is a hint, not an authority.** When a doc and the code
disagree, the code wins and the disagreement gets cited.

---

## nkb_backend: no `project_docs/` at all

`nkb_backend` has **no `project_docs/` directory**. It is the least documented of the
three repositories despite being the only deployable and the owner of every entry point,
all settings, and the database configuration.

Practical consequence: for any question about deployment, routing, settings, cron, or
Lambda wiring, there is no documentation to consult. Source is the only authority.

---

## nkb_assessment_backend

### The "exam eligibility module" does not exist

No module, app, class, or named service implements exam eligibility. Eligibility is
validation logic **inlined inside** `nkb_exam/interactors/start_exam_attempt_for_user.py`
and `nkb_assessment/interactors/start_assessment_attempt_for_user.py`.

This matters because it is a natural thing to ask for by name, and the honest answer is
"there is no such component, here is where the logic actually lives."

### Undeclared dependency on nkb_learning_backend

`pyproject.toml` does not declare `nkb_learning_backend`, but three adapters import it
lazily at call time. Nothing documents this. See
[cross-repo-dependencies.md](cross-repo-dependencies.md).

### Orphaned signal receivers

Receivers for `end_exam_sender` and the two Woolf signals were not found in any of the
three repositories. Either they live in an external package or the signals are dead.
UNKNOWN.

---

## nkb_learning_backend

### `COMPLETION_PERCENTAGE_ANALYSIS.md` claims a fix that is not in the code

**This is the most consequential gap found.**

`nkb_learning_backend/COMPLETION_PERCENTAGE_ANALYSIS.md` (untracked) opens with
"**Fix Status:** ✅ **FIXED** — Override `_update_completion_percentage()` in V2" and
closes with a `Code Change Summary` naming
`nkb_resources/interactors/dependent_resource_availability_v2.py` and
"Added method override: `_update_completion_percentage()` (~60 lines)".

`dependent_resource_availability_v2.py` is 225 lines and defines only:
`get_updated_completion_percentage_of_parent_resources_recursively`,
`_calculate_average_completion_percentage_of_child_resources`,
`_update_resource_id_wise_completion_details_dict`, and
`_remove_resources_with_unchanged_completion_details`.

There is **no `_update_completion_percentage` override.** The float-vs-dict defect the
document describes is still live. Anyone reading the analysis document would conclude
the bug is closed.

Evidence: `COMPLETION_PERCENTAGE_ANALYSIS.md:9,444-457` vs
`dependent_resource_availability_v2.py:1-225`. Confidence: HIGH.

### `project_docs/nkb_resources.md` claims a Redis caching layer that does not exist

The doc lists "Redis — caching layer for resource and enrollment data" under External
Dependencies. There is **no `CACHES` setting in any settings module** in this repo, and
no `redis`/`cacheops` reference anywhere under `nkb_resources/`.

Redis appears only in `poetry.lock` as a transitive dependency and in `env_beta.sh`
under `REDIS_LEADERBOARD_*` / `IB_USER_ACCOUNTS_REDIS_URL` — both owned by other
packages.

The single cacheops touchpoint in the repo is a local import of `invalidate_obj` in
`nkb_auth/storages/storage_implementation.py:553`, which will fail unless the host
project installs and configures cacheops.

Evidence: `project_docs/nkb_resources.md:294`. Confidence: HIGH.

### `project_docs/nkb_niat.md` omits the entire assessment-attempt practice subsystem

The doc describes `AssessmentAttempt` as "a local record of a student's TOPIN assessment
result … Stored in this app for display; results are not computed here", and lists six
fields.

The code has a whole generation state machine the doc is silent about:
`AssessmentAttemptRecommendedPractice` (practice status, retry/restart counters, locked
questions, practice assessment IDs), four HTTP views (`generate_`, `start_`,
`restart_assessment_attempt_practice`,
`get_assessment_attempt_practice_generation_status`), an atomic claim lock, a Zappa async
worker, and an outbound `create_practice_assessment` call into `nkb_assessment`.

The `AssessmentAttempt` table also has five undocumented fields: `skill_name`,
`skill_level`, `is_disqualified`, `is_grit_assessment`, `org_assessment_tags_json`.

Evidence: `project_docs/nkb_niat.md:31,195-208` vs `nkb_niat/models/models.py:165-219`,
`nkb_niat/interactors/enqueue_generate_assessment_attempt_practice.py:33-70`.
Confidence: HIGH.

### Documentation covers roughly half the apps, and misses the largest ones

`project_docs/` covers 13 apps. Thirty are registered.

Undocumented, by size: `nkb_auth_v2` (the largest app in the repo), `nkb_discussions`,
`nkb_placement_support`, `nkb_auth`, `nkb_user_journey`, `nkb_support`,
`nkb_experiments`, `nkb_courses`, `nkb_learning_resource`, `nkb_projects`, `nkb_webinar`,
`nkb_tagging`, `nkb_vocabulary_core`, `nkb_discussions_integrations`.

Only `nkb_cohort` and `nkb_learning_path` carry their own `docs/`.

### `README.md` describes standalone operation only

The README covers poetry setup, virtualenv, `manage.py build`, `migrate`, `runserver` —
as if this were a self-contained service. It never mentions the package-publication
model, the `nkb_core` / `nkb_load_data` imports into `nkb_backend`, or that
`env_beta.sh` points at `nkb_backend.settings.ccbp_beta`.

An engineer following the README alone would hit `ImportError` on those adapters.

### `requirements_project.txt` contradicts `pyproject.toml` on nearly every pin

| Package | `requirements_project.txt` | `pyproject.toml` |
| --- | --- | --- |
| django | `4.1` | `5.1` |
| ib_common | `>=5.0.0,<6.0.0` | `>=6.0.0,<7.0.0` |
| django-swagger-utils | `>=5.0.0,<6.0.0` | `>=6.0.0,<7.0.0` |
| nkb_assessment_backend | `>=3.0.0,<4.0.0` | `>=5.0.0,<6.0.0` |
| ib_pynamodb | `>=6.0.0,<7.0.0` | `7.0.0` |

The `Dockerfile` and `zappa_settings.json` add a third answer on the runtime: Python 3.7
versus `python = "^3.12"`. The README offers `pip install -r requirements.txt` as an
equal alternative to poetry, so a reader can land on either dependency set.

The same `pyproject` vs `requirements_project` split exists in `nkb_backend`, where the
sibling packages are pinned two major versions apart.

### Vestigial directories

`nkb_coach/` and `nkb_learning_sheet/` look like apps by directory name but contain zero
`.py` files, no `apps.py`, and are absent from `INSTALLED_APPS`. Dead or
partially-deleted — unclear.

Note that `nkb_coach` is also a **real, registered app in `nkb_backend`**. The name
collision is a live risk.

### `add_records_oas.json` is not a project API spec

The file at the learning repo root is a vendored OpenAPI 3.0.3 description of the **Zoho
Creator v2** "add records" endpoint. The string `zoho` appears in no other file in the
repository — nothing consumes it.

---

## A documentation claim the code confirms

Worth recording, because it shows the docs are not uniformly unreliable:

`project_docs/nkb_media_playback.md:100` warns that "`signals.py` is referenced but
missing" and would raise `ModuleNotFoundError` at startup. This is **accurate**.
`nkb_media_playback/apps.py:7-8` does `from nkb_media_playback import signals` inside
`ready()`, and the app's only `.py` files are `apps.py`, `admin.py`, and `__init__.py`.

---

## Security finding (not a documentation gap, but surfaced during this work)

`nkb_learning_backend/env_beta.sh` is **committed to Git** and contains live-looking
credential *values*: `CUSTOM_AWS_ACCESS_KEY_ID`, `CUSTOM_AWS_SECRET_ACCESS_KEY`,
`AWS_DYNAMODB_SECRET_ACCESS_KEY`, `RDS_PASSWORD`, `SECRET_KEY`, `OPENAI_API_TOKEN`,
`LE_TOKEN`.

`.gitignore` carries an `env_*` rule, so the file appears to predate that rule or to have
been force-added.

No value was read out, copied, logged, or validated during this analysis. This needs
human triage: rotate if live, and scrub history if so.
