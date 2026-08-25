# Migration baseline

Captured before the reuse-first refactor began, so that every later change can
be measured against a known-good state rather than against memory.

- **Baseline commit:** `3f8712c` (branch `development`)
- **Migration branch:** `refactor/reuse-first-agent-platform`
- **Captured:** 2026-08-25

The rule this exists to serve: no custom security code is deleted until the
component that replaces it produces the same verdicts recorded here.

## What is in this directory

| File | What it records |
|---|---|
| `acp-policy-boundary.json` | 26 permission cases with verdict and post-migration owner |
| `isolation.json` | 8 filesystem/environment checks, 7 currently open |
| `iam-boundary.json` | 21 AWS authorization checks proving denial comes from AWS |
| `policy-decisions.txt` | The 46 real decisions the running system has made |
| `stack-status.txt` | `scripts/status.sh` at baseline |
| `repo-integrity.txt` | `scripts/verify-product-repos-untouched.sh` at baseline |

Regenerate the first two with:

```bash
node tests/security/run-policy-tests.mjs --json evaluations/migration-baseline/acp-policy-boundary.json
bash tests/security/run-isolation-tests.sh --json evaluations/migration-baseline/isolation.json
bash tests/security/run-iam-tests.sh      --json evaluations/migration-baseline/iam-boundary.json
```

## Results

**ACP permission boundary: 26/26 as expected.** Shell, MCP, AWS-operation and
SQL gating all behave as the policy describes. Two cases are regressions drawn
from DBHub's own advisories — the `--` comment bypass (`GHSA-j656-3hf2-fvjc`)
and a side-effecting `SELECT` (`GHSA-mwwr-p57h-56pf`) — and both are denied
today. They are here because the migration replaces our SQL classifier with
DBHub's, and DBHub shipped both of these bugs; the cases must keep passing
after the swap.

**Isolation: 1/8 closed.** The seven open gaps are the Phase 2 work:

| Gap | Why it is open |
|---|---|
| Three product repos writable | `repos/` holds symlinks to working copies; a symlink is fully writable |
| 4 committed credential files reachable | Tracked in git, so a clean clone reproduces them |
| Host `~/.aws` readable | No mount boundary exists yet |
| Host `~/.cursor` readable | Same |
| `aws` CLI on PATH | An entire bypass path around MCP and ToolHive |

## How the policy suite works

`tests/security/fake-agent/agent` impersonates the Cursor CLI. The runner puts
it first on `PATH`, the shim spawns `agent acp` and gets the fake instead, and
the fake issues `session/request_permission` in Cursor's exact wire format. The
policy code under test is unmodified and cannot tell the difference, so a pass
means the shipped decision path returned that verdict — not that a
reimplementation of it did.

This works because of a finding that also constrains the whole migration: ACP
permissions are **cooperative, not interceptive**. Across 3MB of recorded
traffic Cursor called `fs/read_text_file`, `fs/write_text_file` and
`terminal/create` zero times, and `session/request_permission` 49 times. Cursor
reads files, writes files and runs commands itself, and merely asks first. No
ACP proxy — ours, the official SDK, or the conductor — can gate an operation
Cursor performs in-process. Only the sandbox can. That is why Phase 2 comes
before the ACP rewrite.

## IAM boundary: 20/21 as expected, 0 unexpected

This is the one result that does not depend on our code being correct, which
makes it the gate for deleting the custom AWS parser in Phase 5. Identity is
`arn:aws:iam::934167421030:user/nkb-agent-readonly-alpha`. Seven destructive
calls return `AccessDenied` from AWS, three granted reads succeed, and nine
actions return `explicitDeny` from the IAM simulator.

The test runs in two tiers, and the reason is worth keeping. A live call proves
real-world behaviour but cannot always isolate authorization: SQS resolves the
queue before evaluating IAM, so `sqs delete-queue` against an absent queue
returns `NonExistentQueue` regardless of permissions. Read naively that looks
like an allow, and on the first run this suite reported exactly that — a false
positive that would have sent someone hunting a non-existent hole in the
policy. `iam simulate-principal-policy` settles it: `explicitDeny`. The live
tier now records that outcome as inconclusive and the simulator tier answers
it, because the simulator decides authorization without performing the action.

The simulator needs a profile that can read IAM, which the agent identity
deliberately cannot. That tier therefore skips rather than fails when the
profile is absent, so the suite still runs in CI or on a fresh machine.

Every denied call is safe by construction: each targets a resource name that
does not exist, so an unexpected allow still fails on lookup. There is no
ordering of events in which this suite deletes anything.
