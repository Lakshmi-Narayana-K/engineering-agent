# nkb_assessment_backend — navigation profile

Structured metadata: [`context/services/nkb_assessment_backend.yaml`](../../context/services/nkb_assessment_backend.yaml)

## What it is

A library of 19 Django apps covering assessment and evaluation, published as pip packages
and installed into `nkb_backend`. It also carries a legacy standalone Zappa deployment
config, which makes it look self-contained — it is not.

Registered apps: `nkb_assessment_backend/settings/base_swagger_utils.py:25-45`

## Where to look first

| Question | Location |
| --- | --- |
| Question authoring and banks | `nkb_question/` |
| Exam definitions and attempts | `nkb_exam/` |
| Assessment attempts, submission, scoring | `nkb_assessment/` |
| Code evaluation dispatch | `nkb_question/adapters/compile_box_service_adapter_v3.py` |
| What other repos can call | `<app>/interfaces/service_interface.py` |
| Certificates | `nkb_certificate/` |
| Practice, contests, plagiarism, leaderboard | `nkb_coding_practice/`, `nkb_coding_contest/`, `nkb_plagiarism/`, `nkb_leaderboard/` |

## The two flows that leave this repo

**Code evaluation (SQS, asynchronous).**
`nkb_question/adapters/compile_box_service_adapter_v3.py:91-94` publishes to a
per-language SQS queue. An external CompilerBox worker evaluates. The response is consumed
by **`nkb_backend`**, not by this repo, and dispatched back in-process. This repo cannot
close its own loop.

The queue base URL comes from `settings.SQS_COMPILER_BOX_QUEUE_BASE_URL`, which is defined
only in `nkb_backend`. This code path cannot run outside the composed deployment.

**Calls into `nkb_learning_backend` (in-process, lazy, undeclared).**
Three adapters import learning apps at call time:
- `nkb_coding_practice/adapters/coding_core_service_adapter.py:75`
- `nkb_exam/adapters/learning_resource_service_adapter.py:19`
- `nkb_question/adapters/learning_path_service/learning_path_service_adapter.py:7`

None of these appear in `pyproject.toml`. Because the imports are deferred inside property
and method bodies, the package installs and imports cleanly standalone — the failure only
appears at call time.

## Traps

**There is no exam eligibility module.** This is the single most likely question to be
answered wrongly. No module, app, class, or service implements it. Eligibility is
validation logic inlined inside:
- `nkb_exam/interactors/start_exam_attempt_for_user.py`
- `nkb_assessment/interactors/start_assessment_attempt_for_user.py`

**`nkb_leaderboard` is not `nw_leaderboard` or `ib_leaderboard`.** The latter two are
separate external pip packages outside all three repos.

**`interfaces/service_interface.py` is not RPC.** Its methods are plain `@staticmethod`s
that instantiate the target app's storage and interactor in the same process. See
`nkb_exam/interfaces/service_interface.py:197-208`.

**Orphaned signals.** Receivers for `end_exam_sender` and the two Woolf signals were not
found in any of the three repos.

**`pytest.ini` excludes `nkb_learning_backend/settings`** from collection — evidence that a
co-checkout layout is expected, and a useful hint that the two repos are meant to sit
side by side.
