# nkb_learning_backend — navigation profile

Structured metadata: [`context/services/nkb_learning_backend.yaml`](../../context/services/nkb_learning_backend.yaml)

## What it is

The largest of the three by app count: 30 Django apps covering the learning content tree,
per-user progress, authentication, scheduling, discussions, IDE tooling, cohorts, and the
NIAT institute experience. Published as pip packages and installed into `nkb_backend`.

The proof that `nkb_backend` is the real host lives in this repo:
`env_beta.sh:1,11,51` sets `DJANGO_SETTINGS_MODULE=nkb_backend.settings.ccbp_beta` and
`function=nkb-backend-ccbp-beta`. `nkb_learning_path/docs/nkb_backend_integration.md:3`
states it in prose.

Registered apps: `nkb_learning_backend/settings/base_swagger_utils.py:24-55`

## Where to look first

| Question | Location |
| --- | --- |
| Content tree, unlock rules, progress | `nkb_resources/` |
| Current authentication | `nkb_auth_v2/` |
| Legacy auth, roles, feature flags | `nkb_auth/` |
| Schedules, growth cycles, IDP | `nkb_learning_path/` |
| Job sections, TOPIN attempts, resumes | `nkb_placement_support/` |
| NIAT schedule, practice generation | `nkb_niat/` |
| Event glue around progress | `nkb_resources_extensions/` |
| Discussions | `nkb_discussions/` |

## Learner progress — the core subsystem

Owned entirely by `nkb_resources`. Full symbol chain and algorithm in
[`../request-flows.md`](../request-flows.md#learner-progress-rollup).

The short version: a bottom-up recursive rollup. Leaves are written directly, ancestors
recomputed from children. `CompletionStatus` is derived from percentage, never stored
independently. State lives in `UserResource`, `UserLinkedToUnitCompletionDetails`, and
`UserResourceProgressLog` (the only DynamoDB model in the repo).

**There is a live defect.** `DependentResourceAvailabilityV2` does not override
`_update_completion_percentage`; it inherits V1's float-shaped version while V2's
recursion expects dicts. Two entry paths select different classes for the same operation —
the ib_events handler uses V2, the cross-app `ServiceInterface` uses V1. And
`COMPLETION_PERCENTAGE_ANALYSIS.md` claims this is fixed when it is not. See
[`../documentation-gaps.md`](../documentation-gaps.md).

## Authentication — both apps are live

`nkb_auth_v2` is current: OAuth authorization-code exchange, device restriction, enroll
plans, onboarding, face auth. It is the largest app in the repo.

`nkb_auth` is legacy (password/OTP) but **is not dead**. It still owns `UserRole`,
`UserFeatureFlagV2`, Mattermost linkage, signed cookies, and the user-extra-details
storage that `nkb_auth_v2`'s own login view imports
(`nkb_auth_v2/views/login_v1/api_wrapper.py:16-21`).

Both expose `login_v1` and `refresh_auth_tokens_v1` simultaneously. Which one clients
actually use is not determinable from this repo.

## What comes in from outside

**No SQS. No SNS. No inbound assessment webhooks.** Everything inbound arrives through 23
`ib_events` `@register` subscription handlers.

Assessment-related inbound is from **TOPIN**, an external vendor — not from
`nkb_assessment_backend`:
- `nkb_placement_support/sub_handlers/topin_assessment_attempt_end_sub_handler.py:11-48`
- `nkb_auth_v2/sub_handlers/topin_assessment_attempt_end_sub_handler.py:14` — a second,
  independent handler on the *same* subscription

The attempt-end handler is a trigger, not a data carrier: it calls back out to TOPIN over
HTTP to pull scores (`update_attempt_result_interactor.py:28-89`). It is idempotent.

## Traps

**`mark_unit_as_completed_handler` is not about assessments.** Despite the name, it
registers on the AI-interview subscription.

**Two generations of swagger tooling coexist** — `django_swagger_utils.drf_server` in
older views, `dsu.dsu_gen.openapi` in newer ones.

**`urls.py:27-40` silently swallows `ImportError` per app.** A failed `manage.py build`
produces a missing route, not a startup failure.

**`nkb_coach/` and `nkb_learning_sheet/` contain zero `.py` files** and are not registered.
`nkb_coach` also collides with a real registered app in `nkb_backend`.

**`add_records_oas.json` at the repo root is a vendored Zoho Creator spec**, not a project
API document. Nothing consumes it.

**No `CACHES` setting exists** despite one cacheops call site and a documentation claim of
Redis.

**Security: `env_beta.sh` is committed with live-looking credential values.** Flagged for
human triage; no value was read out or validated.
