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
| `policy-decisions.txt` | The 46 real decisions the running system has made |
| `stack-status.txt` | `scripts/status.sh` at baseline |
| `repo-integrity.txt` | `scripts/verify-product-repos-untouched.sh` at baseline |

Regenerate the first two with:

```bash
node tests/security/run-policy-tests.mjs --json evaluations/migration-baseline/acp-policy-boundary.json
bash tests/security/run-isolation-tests.sh --json evaluations/migration-baseline/isolation.json
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

## Not yet captured

**Live IAM denial.** Every AWS case above is denied by our policy layer before
a request reaches AWS, so these results prove our parser works, not that IAM
would refuse. Proving that requires issuing a genuinely denied write (for
example `ecs:DeleteService`) with the scoped credentials and recording the
`AccessDenied`. It is safe in that it cannot succeed, but it is still a write
attempt against a real account, so it needs explicit approval before it runs.
It is the gate for deleting the custom AWS parser in Phase 5 and cannot be
skipped.
