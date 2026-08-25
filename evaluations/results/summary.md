# Evaluation Run — 2026-08-25

Path exercised: Agent Canvas HTTP API → OpenHands Agent Server → ACP shim → `agent acp`
→ three symlinked repositories. Session mode `ask`. Raw transcripts in `raw/`.

## Graded

| Q | Question | Grade | Note |
| --- | --- | --- | --- |
| Q14 | Where is the exam eligibility module? | **PASS+** | Correctly answered that it does not exist |
| Q11 | What is `TOPIN_BASE_URL`? | **PASS+** | Rejected the trap and caught a second one |
| Q12 | How do assessment results reach learning? | **PASS+** | Correctly ruled out `nkb_assessment_backend` |

`PASS+` means the answer was correct, evidence-backed, and additionally surfaced
something the reference answer did not.

### Q14 — exam eligibility

Asked where the exam eligibility module is. The correct answer is that **no such module
exists**; eligibility is validation inlined in two interactors.

The agent answered exactly that, and got there the right way. It stated mid-run:

> The canvas notes claim there is no exam eligibility module; I'll verify that in the
> real `nkb_assessment_backend` source, not just those docs.

It then ran a filename search for `*eligib*` (0 files), searched `nkb_exam/` and
`nkb_assessment/` (no matches), enumerated 78 interactors, and separated the real hits in
other domains (certificate eligibility, Pinecone plagiarism cleanup) from exam-start
eligibility. It landed on `start_exam_attempt_for_user.py` and
`start_assessment_attempt_for_user.py` with the specific exception types
(`NoExamAttemptsLeftException`, `ExamSlotNotEnabledException`,
`GatedSessionAccessDeniedException`).

This is the behaviour the investigation rule was written for: treat generated context as
a hypothesis, confirm in source, cite the confirmation.

### Q11 — TOPIN_BASE_URL

Correctly identified TOPIN as an external vendor (topin.tech) with no relationship to
`nkb_assessment_backend` (zero matches there), consumed only by
`nkb_learning_backend/nkb_placement_support/adapters/topin_adapter.py`.

Beyond the reference answer, it caught a trap the analysis had not written down: the prod
hostname is `nxtwave-assessments-backend-topin-prod-apis.ccbp.in`, which *reads* like
`nkb_assessment_backend` and is a separate integration host. It also flagged the
ownership inversion — the concrete URLs are defined in `nkb_backend` and never referenced
there, while the only consumer is in `nkb_learning_backend`.

### Q12 — assessment results inbound

Correctly ruled out `nkb_assessment_backend` as the producer, identified `ib_events`
TOPIN subscriptions as the only inbound path, and — importantly — characterised the
handler correctly as a **trigger rather than a data carrier**: it does not persist
`user_score` from the event, it calls `UpdateAttemptResultInteractor`, which pulls scores
back from TOPIN over HTTP.

It also independently found the second handler in `nkb_auth_v2` registered on the same
subscription.

## Not completed

Q06, Q07, and Q08 were run but their answers were lost to a harness defect:
`smoke-test.py` fetched only the first page of conversation events, and these three
investigations exceeded 100 events, so the agent's final message fell outside the page.

The defect is fixed — event fetching now walks `next_page_id` to the end, and the display
no longer truncates at 2000 characters. The runs were not repeated. Note that Q11 and Q12
above ran *before* the truncation fix, so their raw transcripts cut off mid-answer at
2000 characters; the graded portion was sufficient to judge.

Remaining questions in [`../questions.md`](../questions.md) have not been run.

## Reading the raw files

The trailing line

```
FAIL: expected substring 'CURSOR_ACP_CONNECTED' not found in agent output
```

is the harness's default connectivity assertion, not a grade. It appears on every run
that uses a custom `--prompt`.
