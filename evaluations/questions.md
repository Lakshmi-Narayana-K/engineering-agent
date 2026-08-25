# Evaluation Questions

Twenty-four questions for exercising the Agent Canvas → Cursor ACP → multi-repo path.
Each is answerable from local source, and each has a known-correct answer recorded here
so a response can be graded rather than merely read.

Questions are grouped by what they test. Difficulty reflects how easy it is to answer
*wrongly and confidently* — the traps are the point.

Grading criteria live in [expected-answer-format.md](expected-answer-format.md).
Record runs under `results/`.

---

## A. Single-repo comprehension (warm-up)

**Q1.** What is `nkb_backend` responsible for, and how does it differ from the other two
repositories?
*Expect:* composition root / sole deployable; owns settings, root URLconf, DB config, and
all entry points; the other two are pip-installed app libraries. HIGH confidence.

**Q2.** How does an HTTP request get routed to a view in any of these repos? Walk through
one concrete endpoint.
*Expect:* `api_spec.json` → `manage.py build` generates `build/urls.py` → root URLconf
mounts `/api/<app>/` → `api_wrapper.py` → interactor → storage → presenter. Should note
`build/` is gitignored.

**Q3.** Which app owns learner progress calculation, and what are the key classes and
models?
*Expect:* `nkb_learning_backend/nkb_resources`;
`DependentResourceAvailability` / `V2`; `UserResource`,
`UserLinkedToUnitCompletionDetails`, `UserResourceProgressLog` (DynamoDB).

**Q4.** How is completion status determined — is it stored or derived?
*Expect:* derived, never stored independently.
`get_completion_status_based_on_completion_percentage` returns `completed` iff the value
equals `MAX_COMPLETION_PERCENTAGE`.

**Q5.** What background job mechanisms are used across the platform?
*Expect:* Zappa async Lambda tasks, Step Functions as a delayed scheduler, SQS (CompilerBox
only), ib_events, ECS Fargate. Must state there is **no Celery**.

---

## B. Cross-repo dependency (the core capability)

**Q6.** How do these three repositories communicate with each other?
*Expect:* in-process Python imports via `interfaces/service_interface.py`, **not HTTP**.
One SQS edge for CompilerBox. Answering "REST APIs" is a failure.

**Q7.** Trace what happens end-to-end when a learner submits code for a coding question.
*Expect:* assessment publishes to SQS → external CompilerBox → `nkb_backend`'s
`sqs_lambda_handler.py` consumes → dispatches back into assessment in-process. Should note
the asymmetry: assessment publishes but does not consume its own results.

**Q8.** Is there a circular dependency between the repositories?
*Expect:* yes, at runtime. Learning → assessment is declared; assessment → learning is
lazy and **undeclared** in `pyproject.toml`. Build-time graph is acyclic, runtime graph is
cyclic.

**Q9.** If I wanted to extract `nkb_assessment_backend` into a truly independent service,
what would break?
*Expect:* settings it doesn't own (`SQS_COMPILER_BOX_QUEUE_BASE_URL`); the SQS response
consumer lives in `nkb_backend`; undeclared learning imports; shared DB with no routing;
shared `exam_id`/`unit_id` identifier space with no translation layer. Synthesis question
— should reason, not just list.

**Q10.** Does `nkb_learning_backend` call `nkb_assessment_backend` over HTTP?
*Expect:* no. In-process import, declared at `pyproject.toml:63`. Should also flag the
layering violation where one adapter imports assessment's `storage_implementation`
directly.

**Q11.** What is `TOPIN_BASE_URL` and which repo uses it?
*Trap.* Sounds internal; it is an **external** assessment vendor. Used only by
`nkb_learning_backend/nkb_placement_support`. Has nothing to do with
`nkb_assessment_backend`.

**Q12.** How do assessment results get into the learning system?
*Trap.* Not from `nkb_assessment_backend`. Via ib_events subscriptions to **TOPIN**
attempt start/end, handled in `nkb_placement_support`. The handler is a trigger — it calls
back out to TOPIN over HTTP to pull scores.

**Q13.** Which repositories share a database?
*Expect:* all three in the composed deployment; `db_router.py` has no routing and
`allow_relation` always returns `True`. Should acknowledge that cross-deployment sharing
is UNKNOWN.

---

## C. Traps and negative findings

**Q14.** Where is the exam eligibility module?
*Trap — the honest answer is that it does not exist.* Eligibility is inlined in
`StartExamAttemptForUserInteractor` and `StartAssessmentAttemptForUserInteractor`. An
answer that invents a module fails.

**Q15.** Does `mark_unit_as_completed_handler` handle assessment completion events?
*Trap.* No — it registers on the **AI-interview** subscription
(`IB_EVENTS_UPDATE_USER_AI_INTERVIEW_STATUS_SUBSCRIPTION`) despite the name.

**Q16.** Which repo owns `nkb_leaderboard`, and how does it relate to `nw_leaderboard`
and `ib_leaderboard`?
*Trap.* `nkb_leaderboard` is solely `nkb_assessment_backend`'s. The others are separate
**external** pip packages, outside all three repos.

**Q17.** There's an app called `nkb_coach`. Where does it live and what does it do?
*Trap.* It exists in **both** `nkb_backend` (registered, Bedrock AI coach) and
`nkb_learning_backend` (unregistered, zero `.py` files). A good answer names the collision
as a risk.

**Q18.** Does `nkb_learning_backend` use SQS?
*Expect:* no — no producer or consumer anywhere. The only textual match is a test fixture
name. Tests whether the agent distinguishes a real usage from a string match.

**Q19.** `nkb_assessment_backend` and `nkb_learning_backend` each have a
`zappa_settings.json`. Are they deployed independently?
*Expect:* they carry legacy standalone configs, but the composed deployment is what
`env_beta.sh` targets. Whether the standalone ones are live is **UNKNOWN**. Tests
calibration — the right answer includes an admitted unknown.

---

## D. Documentation-vs-code verification

**Q20.** `COMPLETION_PERCENTAGE_ANALYSIS.md` says a completion-percentage bug is fixed.
Is it?
*Expect:* **no.** The document claims a `_update_completion_percentage` override in V2
that does not exist in the 225-line file. The float-vs-dict defect is live. This is the
sharpest doc-vs-code test in the set.

**Q21.** The `nkb_resources` documentation mentions Redis caching. Where is it configured?
*Expect:* it isn't. No `CACHES` setting in any settings module in that repo. Redis appears
only transitively and in env vars owned by other packages.

**Q22.** What are the differences between `DependentResourceAvailability` and its V2?
*Expect:* V2 carries a dict per resource vs V1's float, and propagates `max()` timestamps.
Should surface the inherited-method defect and that two entry paths pick **different
classes for the same operation**.

**Q23.** How complete is the documentation across these repos?
*Expect:* `nkb_backend` has none at all; learning covers 13 of 30 apps and misses its
largest ones; several docs actively disagree with code.

---

## E. Open-ended synthesis

**Q24.** I'm a new engineer joining this team. What do I most need to understand about how
these three repos fit together, and what's most likely to trip me up?
*Expect:* the composition-root model; in-process not HTTP; the cyclic undeclared
dependency; version pin disagreements; the `nkb_coach` collision; that docs are unreliable
and the deployable is undocumented. Tests synthesis and prioritisation across all four
analyses.

---

## Notes on running these

Ask them one per conversation where possible — the point is to test retrieval and
reasoning from a cold start, not follow-up coherence within a warm thread.

Questions 11, 12, 14, 15, 16, 17 are the ones most likely to produce a confident wrong
answer. If the agent passes those, the context layer is doing its job. If it fails them
while passing the rest, the fix is usually a missing cross-reference in
`knowledge/cross-repo-dependencies.md` rather than a prompt change.
