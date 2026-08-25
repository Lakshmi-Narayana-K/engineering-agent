# Request Flows

Traced end-to-end from source. Each flow names the files in order so an answer can cite
the chain rather than describe it abstractly.

## Generic HTTP request

Every app in all three repositories follows the same path. Routing is generated, not
hand-written.

1. **`api_specs/api_spec.json`** — Swagger 2.0. Declares `basePath`, path, HTTP verb,
   `operationId`, `security`, and request/response `$ref`s. This is the authoritative
   route contract.
2. **`python manage.py build`** (a `django_swagger_utils` command) generates
   `<app>/build/urls.py` and validator classes from that spec. `build/` is **gitignored**
   — it is a build artifact, not source. CI runs `manage.py build -at` before pytest.
3. **`nkb_backend/nkb_backend/urls.py:37-44`** mounts `^api/<app_name>/` for every app
   in `INSTALLED_APPS`, including `<app>.build.urls`.
4. **`views/<operation>/api_wrapper.py`** — decorated with the interface/validate
   decorator. Receives `kwargs['user']` (already authenticated) and
   `kwargs['request_data']`. Constructs storage, presenter, and interactor, then calls
   the interactor.
5. **`interactors/`** — business logic. Never touches the ORM.
6. **`storages/`** — interface declared under `interactors/storages/`, implementation
   under `storages/`. Owns all ORM access.
7. **`presenters/`** — builds the response.

In `nkb_learning_backend/nkb_learning_backend/urls.py:27-40`, an `ImportError` for any
app is **silently swallowed**. A failed `manage.py build` degrades to a missing route
rather than a startup error.

### Worked example — `POST /api/nkb_cohort/cohort_courses/v1/`

| Step | File |
| --- | --- |
| Mount | `nkb_learning_backend/urls.py:32` |
| Contract | `nkb_cohort/api_specs/api_spec.json` — `operationId: get_cohort_courses`, `security: [{oauth: [read]}]` |
| Generated routing | `nkb_cohort/build/urls.py` *(gitignored; inferred)* |
| Validation | `nkb_cohort/views/get_cohort_courses/validator_class.py` |
| Entry | `nkb_cohort/views/get_cohort_courses/api_wrapper.py:10-31` |
| Logic | `nkb_cohort/interactors/get_cohort_courses_interactor.py` |
| Data | `nkb_cohort/storages/storage_implementation.py` |
| Response | `nkb_cohort/presenters/get_cohort_courses_presenter_implementations.py` |

## Coding question evaluation (the one async cross-repo flow)

Confidence: HIGH. This is the only cross-repository interaction that leaves the process.

1. A learner submits code. `nkb_assessment_backend/nkb_question` builds an evaluation
   request with a correlating `request_id`.
2. `nkb_question/adapters/compile_box_service_adapter_v3.py:91-94` publishes to a
   per-language SQS request queue
   (`CompilerBox-code-evaluation-request-*-Queue-<lang>`). The queue base URL comes
   from `settings.SQS_COMPILER_BOX_QUEUE_BASE_URL`, which is defined **only** in
   `nkb_backend/nkb_backend/settings/base.py:627-628`.
3. An **external CompilerBox worker** — not in any of these repos — consumes, evaluates,
   and publishes to the response queue.
4. `nkb_backend/sqs_lambda_handler.py:19-26`, wired at
   `nkb_backend/zappa_settings.json:162`, consumes the response.
5. It dispatches the result back into `nkb_assessment_backend` receivers **in-process**,
   correlating on `request_id` / `evaluation_id`.

The asymmetry is worth stating explicitly: assessment publishes but does not consume.
The library depends on the host's Lambda wiring to close its own loop.

## Course unit content assembly

Confidence: HIGH.

`nkb_learning_backend/nkb_resources/utils/get_content_data_util.py:41-84` resolves a
course unit, branches on `unit_type`, and for assessment-backed units calls into
`nkb_assessment_backend` interactors **in-process**.

The learning `unit_id` is passed straight through as the assessment `exam_id` — one
identifier space, no translation layer.

## Async command dispatch

Confidence: HIGH.

`nkb_backend/zappa_command_receiver.py` receives a dotted command path in a Lambda
payload and invokes the corresponding sibling `ServiceInterface` in-process — assessment
at line 21, learning at line 287.

Delayed work is scheduled through AWS Step Functions: callers `start_execution` with
`{"lambda_payload": {"command": "<dotted.path>", ...}, "alarm_datetime": "<iso>"}`
against a scheduler state machine ARN. Three separate ARNs are configured in
`nkb_learning_backend` alone (scheduler, project-submission evaluation, resume creation).

## Learner progress rollup

Confidence: HIGH. Owned entirely by `nkb_learning_backend/nkb_resources`.

**Symbol chain:**

```
update_completion_details_of_resource_wrapper          # :88
  -> update_completion_details_of_resource             # :109
    -> update_completion_details_of_resource_in_transaction   # :140
      -> _update_completion_percentage                 # :364
        -> get_updated_completion_percentage_of_parent_resources_recursively  # :416
          -> update_completion_details_of_resources    # mixin
            -> _user_resource_completion_post_steps    # :180
```

All in `nkb_resources/interactors/dependent_resource_availability.py`.

**Algorithm.** Bottom-up and recursive. Leaf completion is written directly; every
ancestor is recomputed from its children. Two aggregation strategies exist:

- `_calculate_average_completion_percentage_of_child_resources` — plain mean over
  children.
- `_calculate_course_completion_from_topic_children` — per-topic mean over the
  *version's* unit list, then mean over topics. Selected only when the parent is a
  `course` **and** its children are a subset of the version's topic keys.

`CompletionStatus` is derived, never stored independently:
`get_completion_status_based_on_completion_percentage` (`:406-414`) returns `completed`
iff the value equals `MAX_COMPLETION_PERCENTAGE`, else `in_progress`.

**Persistence.** `UserResource` (unique on `(user_id, resource)`),
`UserLinkedToUnitCompletionDetails`, and `UserResourceProgressLog` — the last being a
**DynamoDB** PynamoDB model with an LSI and a `ResourceCompletionGSI`. Writing the
DynamoDB log is gated by `settings.UPDATE_USER_RESOURCE_PROGRESS_LOG`, which defaults to
`True` via `getattr` and is not defined in any settings module in the learning repo.

**V1 vs V2 — and a live defect.** `DependentResourceAvailabilityV2` subclasses V1. V2
carries a *dict* per resource (`{completion_percentage, last_progress_datetime}`) and
propagates the parent timestamp as `max()` of its children's; V1 carries a bare float.

V2 does **not** override `_update_completion_percentage`. It inherits V1's version,
which builds `{resource_id: float}` and then calls the polymorphically-resolved V2
recursion, which expects dicts. V2's
`_calculate_average_completion_percentage_of_child_resources` subscripts
`completion_details_dict["completion_percentage"]` after only a falsy check, so a truthy
float subscript raises `TypeError`.

Compounding it, two entry paths select **different classes for the same operation**:
- `nkb_resources_extensions/sub_handlers/mark_unit_as_completed_handler.py:50-53` → V2
- `nkb_resources/interfaces/service_interface.py:171-173` → V1

**No generic "mark unit complete" HTTP endpoint was found** in `nkb_resources/views/` —
it contains only two read endpoints. Writes arrive via the ib_events handler, via
`interfaces/service_interface.py`, or from `nkb_interactive_video` /
`nkb_learning_resource`. A generic endpoint may exist in `nkb_backend`. Confidence:
MEDIUM.

## Exam / assessment eligibility

Confidence: HIGH — and the finding is a negative one.

**There is no eligibility module, app, or named service.** Searching for one will fail.

Eligibility is decided by validation code **inlined inside two interactors**:
- `nkb_assessment_backend/nkb_exam/interactors/start_exam_attempt_for_user.py`
- `nkb_assessment_backend/nkb_assessment/interactors/start_assessment_attempt_for_user.py`

Any question about "where eligibility is checked" must point at those interactors, not
at a component.

## Assessment results into learning

Confidence: HIGH.

`nkb_learning_backend` has **no inbound HTTP webhook and no SQS/SNS consumer** for
assessment results. Everything inbound arrives through `ib_events` `@register`
subscriptions.

The two genuinely assessment-driven handlers are in `nkb_placement_support` and
subscribe to **TOPIN** (the external platform), not to `nkb_assessment_backend`:

- `topin_assessment_attempt_end_sub_handler.py:11-48`
- `topin_assessment_attempt_start_sub_handler.py:17`

The attempt-end handler is a **trigger, not a data carrier**. It calls
`UpdateAttemptResultInteractor.update_attempt_result`
(`nkb_placement_support/interactors/update_attempt_result_interactor.py:28-89`), which
makes an **outbound HTTP call back to TOPIN** to pull the scores, maps status through
`ATTEMPT_STATUS_MAP`, evaluates `qualification_criteria_str`, and writes
`UserSlotAttempt`. It is idempotent — it returns early when
`attempt_status == completed`.

`nkb_auth_v2` registers a **second, independent** handler on the same subscription
(`nkb_auth_v2/sub_handlers/topin_assessment_attempt_end_sub_handler.py:14`). Two apps
react to one event.

## Certificate poster generation

Confidence: MEDIUM.

`nkb_assessment_backend/nkb_certificate/adapters/ib_events_service_adapter.py:47-51`
emits `GENERATE_CERTIFICATE`. An **external** rendering service emits `POSTER_GENERATED`.
All three repos subscribe to `POSTER_GENERATED` in parallel. They are co-subscribers to
a third party, not producer and consumer of each other.

## Bulk content load from spreadsheets

Confidence: HIGH.

`nkb_backend/nkb_load_data` reads Google Sheets and writes into both assessment and
learning models **in-process**, using each app's storage layer directly.
