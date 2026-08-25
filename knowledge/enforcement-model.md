# Enforcement Model

How this workspace actually constrains the agent, which controls are real, and which
ones look like controls but are not. Every claim here was verified empirically on
2026-08-25 by attempting the action and observing the result — not inferred from docs.

This matters more than usual: the workspace is about to be given production database,
CloudWatch, and Rapid7 access, and three of the controls originally believed to be
protective turned out not to be.

## What was tested and what happened

| Attempted | Result | Verified how |
| --- | --- | --- |
| Write a file in `ask` mode | **Blocked** | File was never created on disk |
| `id -un` in `ask` mode | **Ran** | Returned a username |
| `aws sts get-caller-identity` | **Ran** | Returned a real account and IAM user ARN |
| Rapid7 MCP tools present | **Yes**, including mutating ones | Agent listed `update_alert`, `delete_investigation`, `create_detection_rule` |
| `.cursor/cli.json` deny rules | **Not applied** | `aws` still ran after a full restart |
| Project `.cursor/mcp.json` | **Ignored** | Three attempts; only global `~/.cursor/mcp.json` loaded |
| Read `env_prod.sh` via the file tool | **Permitted** | Agent reported the read succeeded; zero `read` entries in the audit log |

After the shim gained permission enforcement, re-tested:

| Attempted | Result | Verified how |
| --- | --- | --- |
| `aws sts get-caller-identity` | **Blocked** | `matched denied pattern /\baws\b/` |
| `git log && aws s3 ls` (compound) | **Blocked** | Denied on the second segment |
| `insightidr` MCP tool | **Blocked** | `MCP server 'insightidr' is not in mcp.allowedServers` |
| `cloudwatch-alpha:recommend_indexes_account` | **Blocked** | Not allowlisted, while a sibling tool on the same server succeeded |
| `cloudwatch-alpha:describe_log_groups` | **Allowed** | Returned real log group names as `nkb-agent-readonly-alpha` |
| Read `env_prod.sh` | **Still permitted** | Unchanged — see below |

## Controls that do NOT work in ACP mode

### Session mode `ask` — partial only

`ask` mode genuinely blocks file writes. It does **not** block shell execution. A
read-only shell still reaches `aws`, `psql`, `curl`, and every interpreter, so mode
alone cannot keep this workspace off the production network.

The earlier belief that `ask` removed shell came from observing 54 tool calls that used
only `read` and `search`. That was the agent not needing shell, not being unable to use
it.

### File reads — not gated at all, by anything

This is the one open hole. Cursor's ACP mode does not emit `session/request_permission`
for file reads, so the shim never sees them and cannot deny them. Confirmed by counting:
across every session recorded in `runtime/logs/acp-permissions.jsonl` there are **zero**
entries of kind `read`. The `sensitivePatterns` check does apply to shell commands and
MCP titles, but for reads it is dead code.

Consequence: every file under `repos/` is readable, including eleven credential-bearing
files — `env_prod.sh`, `env_beta.sh`, the `*.encrypted` archives, and four BigQuery /
Google service-account JSONs whose private keys are plaintext. No audit record is produced
when they are read.

Mitigations, in order of strength:

1. **The files should not be there.** In the deployed design repos are cloned from
   CodeCommit, which contains none of them, and secrets arrive as injected environment
   variables. This exposure is an artifact of pointing the agent at local working copies.
2. **Relocate them** outside the symlinked trees. All eleven are local and gitignored, so
   moving them breaks nothing in the repos — though code may load the BigQuery JSONs from
   a relative path, so those need checking first.
3. **`.cursorignore`** at the workspace root. Unverified under ACP, and worth genuine
   scepticism: `.cursor/cli.json` is honoured by the IDE and ignored by ACP, so IDE
   documentation is not evidence about ACP behaviour. Cursor also refuses to let an agent
   write this file, which is why it must be created by hand.

### Project-scoped `.cursor/mcp.json` — never loaded

ACP reads only the global `~/.cursor/mcp.json`. This is why InsightIDR kept appearing
while `nkb-probe` and `cloudwatch-alpha` never did, across three separate attempts.

`agent acp` accepts no flag to redirect the config directory — it accepts no options at
all — so the shim overrides `HOME` to `runtime/cursor-home` instead. The config Cursor
reads is then the repo's own, and servers from the developer's machine cease to exist
rather than merely being denied. Isolating `HOME` also puts Cursor's cached login out of
reach, which is why `CURSOR_API_KEY` becomes mandatory; that is the same credential path
the deployed container uses, so local and production stop diverging.

### `.cursor/cli.json` — parsed, validated, and ignored

The file is read and strictly schema-validated. An unrecognised key (`_comment`) caused
`agent acp` to abort outright, which proves it is genuinely parsed.

It nonetheless has **no effect on ACP sessions**. After a clean restart with `Shell(aws)`
in the deny list, `aws sts get-caller-identity` still ran to completion.

The reason is architectural. In ACP mode Cursor does not adjudicate permissions itself —
it **delegates** each gated action to the client with a `session/request_permission`
call. Cursor's own permission config governs interactive and print mode, not this path.
Keep the file for defence in depth and for anyone running the CLI directly, but do not
rely on it here.

### `agent mcp disable <server>` — does not prevent attachment

`agent mcp list` reports `insightidr: disabled`, yet the InsightIDR server was running as
a child of the ACP process and its full tool set — including mutating tools — was
offered to the agent. Confirmed when `stop.sh` tore down the stack and killed the
InsightIDR process as a POC descendant.

A project-level `.cursor/mcp.json` listing only a different server did not displace it
either. The project MCP server reported `not loaded (needs approval)` while the global
one remained attached.

## The control that does work

**The ACP shim adjudicates every permission request.**

`runtime/cursor/cursor-acp-shim.mjs` sits between Agent Server and `agent acp` and sees
every `session/request_permission`. Previously it forwarded them to Agent Server, which
auto-approves unconditionally — that is why `aws` ran. It now evaluates each request
against `config/acp-permissions.json` and answers directly, so the outcome does not
depend on client behaviour at all.

The request carries the command in `toolCall.title` (backtick-wrapped) and the tool class
in `toolCall.kind`. The response selects one of the offered options by `optionId`;
`reject_once` is the deny.

Note that `toolCall.rawInput` is always empty — Cursor does not populate it over ACP —
so policy matches on `title`. This is also why tool inputs render blank in Agent Canvas.

### Policy semantics

Defined in [`../config/acp-permissions.json`](../config/acp-permissions.json), evaluated
**fail-closed**: anything not explicitly permitted is denied, and an unreadable or
malformed policy denies everything rather than defaulting open.

1. Regex `deniedPatterns` against the raw command — catches `aws`, `psql`, `curl`,
   command substitution, redirection, and the credential file names.
2. Compound commands are split on `&&`, `||`, `;`, and `|`, and **every segment** is
   checked independently.
3. Each segment's command base must appear in `allowedCommands`, after stripping any
   leading `VAR=value` assignments and any path prefix.
4. `git` additionally requires a read-only subcommand. `branch` and `tag` are excluded
   deliberately — `git branch -D` and `git tag -d` are destructive and flag parsing is
   not worth the risk.

### Verified behaviour

```
`id -un`                            -> deny   'id' is not in allowedCommands
`aws sts get-caller-identity`       -> deny   matched denied pattern /\baws\b/
`git log --oneline -1`              -> allow  all segments permitted
`git log --oneline -1 && aws s3 ls` -> deny   matched denied pattern /\baws\b/
```

The fourth case is the important one: the compound-command bypass is closed, and the
whole command is rejected rather than partially executed.

Denials are surfaced to the user in chat as a **Blocked by workspace policy** note with
the reason, so a refusal is visible rather than silent.

### Audit trail

Every decision is appended to `runtime/logs/acp-permissions.jsonl` with timestamp,
decision, reason, tool kind, and command. This is the only per-action audit record the
workspace produces, and it is what a review would be reconstructed from.

## Still unresolved

**MCP tools are not yet gated.** The policy file has an `mcp.allowedServers` block that
is currently empty, but the shim's `evaluate()` only parses `execute` commands. MCP tool
calls arrive with a different `kind` and are currently allowed through. **The InsightIDR
server remains attached with mutating tools available.** This must be closed before any
RDS, CloudWatch, or Rapid7 server is deliberately added.

**AWS credentials are ambient.** The agent inherits the developer's personal AWS
credentials with their full IAM permissions. The shell path to them is now blocked, but
an MCP server would use them directly. A dedicated read-only role is required.

## Implications for adding production MCPs

1. Gate MCP tool calls in the shim by `server:tool`, default-deny, before attaching
   anything that reaches a live system.
2. Never rely on an MCP server's own `--readonly` flag as the sole control; enforce at
   the shim and again at the IAM/database-grant layer.
3. Prefer credentials the workspace cannot escalate: a scoped IAM role, a read replica,
   and a `GRANT SELECT`-only database user.
4. Remember the ACP process is long-lived and shared across conversations. Policy and
   MCP changes take effect only after a restart.
