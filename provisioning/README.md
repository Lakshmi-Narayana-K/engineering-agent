# Provisioning — NKB Engineering Agent

What the agent platform needs from AWS, in the order it should be created.

Two phases. **Phase 1** is self-service in `nxtwave-alpha` and proves the pattern
end to end. **Phase 2** is the production ask and is the part to forward to the
platform team — it is deliberately the same design, so nothing is redesigned
between them.

Nothing here requires an IAM user or a long-lived access key.

---

## Why this shape

The agent reads source code, production logs, infrastructure state and
(eventually) database rows, then sends selected context to an LLM. That
combination does not fit inside an existing application account's threat model,
so the runtime gets its own account and reaches everything else through
explicitly granted, read-only cross-account roles.

Two properties are load-bearing and worth preserving through review:

1. **The target account grants the access, not the agent account.** Each
   workload account decides what the agent may see by editing its own role.
   Revocation is local to that account and needs no coordination.
2. **The agent cannot choose which account it talks to.** The account is fixed
   per MCP server process by `AWS_PROFILE`. Account selection is configuration,
   never a decision the model makes at runtime.

---

## Phase 1 — `nxtwave-alpha` (self-service, ~30 minutes)

Goal: prove `local agent → AssumeRole → CloudWatch read` works, with the tool
allowlist enforcing correctly, before asking anyone for production access.

Alpha stands in for a workload account. Your existing IAM user stands in for the
ECS task role. Everything else is identical to production.

### 1.1 Create the read-only role

In `nxtwave-alpha`, create role **`nkb-agent-readonly`**.

- Trust policy: [`iam/alpha-agent-readonly-trust.json`](iam/alpha-agent-readonly-trust.json)
  — replace `<ALPHA_ACCOUNT_ID>` and `<YOUR_IAM_USER>`.
- Permission policy: [`iam/agent-readonly-permissions.json`](iam/agent-readonly-permissions.json)
  — used unchanged in production.

Set the maximum session duration to 1 hour.

### 1.2 Add a local profile

In `~/.aws/config`:

```ini
[profile nkb-agent-alpha]
role_arn       = arn:aws:iam::<ALPHA_ACCOUNT_ID>:role/nkb-agent-readonly
source_profile = default
region         = <REGION>
```

`default` is used only to perform the AssumeRole. It is never passed to the
agent — the shim scrubs inherited AWS variables from the child environment.

### 1.3 Verify the identity before involving the agent

```bash
aws sts get-caller-identity --profile nkb-agent-alpha
# expect: arn:aws:sts::<ALPHA_ACCOUNT_ID>:assumed-role/nkb-agent-readonly/...

aws logs describe-log-groups --profile nkb-agent-alpha --max-items 5   # succeeds
aws ec2 describe-instances   --profile nkb-agent-alpha                 # must fail
```

The second failure matters as much as the first success. If it returns data, the
permission policy is wider than intended — stop and fix it before continuing.

### 1.4 Attach the CloudWatch MCP server

Add to `.cursor/mcp.json`, then allowlist its tools in
`config/acp-permissions.json` under `mcp.allowedServers`.

```json
"cloudwatch-alpha": {
  "command": "uvx",
  "args": ["awslabs.cloudwatch-mcp-server@latest"],
  "env": { "AWS_PROFILE": "nkb-agent-alpha", "AWS_REGION": "<REGION>" }
}
```

The server exposes 19 tools. Allowlist ten; leave the rest denied:

| Allowlist | Leave denied | Why |
| --- | --- | --- |
| `describe_log_groups`, `analyze_log_group` | `execute_cwl_insights_batch` | queries across **accounts and regions** — defeats account pinning |
| `execute_log_insights_query`, `get_logs_insight_query_results`, `cancel_logs_insight_query` | `recommend_indexes_account`, `recommend_indexes_loggroup` | account-wide scans, billable |
| `get_metric_data`, `get_metric_metadata`, `analyze_metric` | `execute_promql_*`, `get_promql_*` (5 tools) | need Managed Prometheus, not in scope |
| `get_active_alarms`, `get_alarm_history` | `get_recommended_metric_alarms` | advisory, not investigative |

### 1.5 Confirm the controls actually hold

Through the agent, not the CLI:

- A log query against an alpha log group returns data.
- Asking it to use a non-allowlisted tool is refused, with the reason visible in
  chat and a `deny` row in `runtime/logs/acp-permissions.jsonl`.
- Asking it to reach Rapid7 or run `aws` directly is refused.

Only after all three pass is it reasonable to request production access.

> **Cost note.** `execute_log_insights_query` is Logs Insights, billed per GB
> scanned. An agent that retries a broad query over a wide time range can spend
> real money. Set a billing alarm on the alpha account first.

---

## Phase 2 — Production (platform team)

### 2.1 New account

Create **`nxtwave-agent-platform-dev`** under the `nxtwave-tech` Organization,
with the standard networking, logging and guardrail baseline.

It hosts the agent runtime only — Canvas, Agent Server, Cursor ACP, ECS, ECR,
Secrets Manager. No application resources, no application data.

### 2.2 Roles in the agent account

**`nkb-agent-runtime-role`** — the ECS task role.

- Trust: [`iam/prod-agent-runtime-trust.json`](iam/prod-agent-runtime-trust.json)
- Permissions: [`iam/prod-agent-runtime-permissions.json`](iam/prod-agent-runtime-permissions.json)

Its only permission is `sts:AssumeRole` against a named list of read-only roles.
It can read nothing directly — deliberately, so that adding a workload account is
a policy edit rather than a new grant of capability.

**`nkb-agent-ecs-execution-role`** — the ECS execution role.

- Same trust policy.
- Attach `service-role/AmazonECSTaskExecutionRolePolicy`.
- Plus [`iam/prod-ecs-execution-secrets.json`](iam/prod-ecs-execution-secrets.json).

The execution/task split matters: the **execution** role reads the Cursor API key
from Secrets Manager and injects it before the container starts. The **task**
role — the one the agent actually runs as — never has Secrets Manager access at
all.

### 2.3 Secret

Create `nkb-agent/cursor-api-key` in Secrets Manager, holding a key from a Cursor
**service account** — not a personal login. Referenced from the task definition's
`secrets` block, never `environment`.

### 2.4 Role in each workload account

In every account the agent must investigate, create **`nkb-agent-readonly`**:

- Trust: [`iam/prod-agent-readonly-trust.json`](iam/prod-agent-readonly-trust.json)
  — trusts only `nkb-agent-runtime-role` in the agent account.
- Permissions: [`iam/agent-readonly-permissions.json`](iam/agent-readonly-permissions.json)
  — the same file used in alpha.

Use this custom policy rather than the AWS managed `ReadOnlyAccess`, which grants
far more than needed and expands silently when AWS adds services to it.

### 2.5 Container configuration

One profile per target account, baked into the image:

```ini
[profile assessment-prod]
role_arn          = arn:aws:iam::<ASSESSMENT_ACCT>:role/nkb-agent-readonly
credential_source = EcsContainer
region            = <REGION>
```

`credential_source = EcsContainer` is the only line that differs from the local
setup, where it is `source_profile = default`.

---

## Database access is separate

The IAM policy above grants `rds:Describe*` — metadata only. It does not permit a
single row to be read. SQL access needs two additional things, because a database
is a network service rather than an AWS API:

**Authorization** — IAM database authentication enabled on the cluster, plus a
dedicated DB user. See [`db/agent-readonly-user.sql`](db/agent-readonly-user.sql).
With IAM auth there is no database password anywhere; the agent generates a
15-minute token.

**Network path** — the agent's VPC must reach the RDS **reader** endpoint, via
VPC peering or Transit Gateway. Point at the reader (`cluster-ro-…`), not the
writer: Aurora replicas are `innodb_read_only`, so writes fail at the engine
regardless of grants. That is the strongest available control and it costs
nothing.

Then extend the workload account's `nkb-agent-readonly` policy with:

```json
{ "Sid": "DbConnectAsReadOnlyUserOnly",
  "Effect": "Allow",
  "Action": "rds-db:connect",
  "Resource": "arn:aws:rds-db:<REGION>:<ACCT>:dbuser:<CLUSTER_RESOURCE_ID>/nkb_agent_readonly" }
```

`<CLUSTER_RESOURCE_ID>` is the opaque `cluster-ABC123…` value from
`aws rds describe-db-clusters --query 'DBClusters[].DbClusterResourceId'`, **not**
the cluster name. Using the name produces an access-denied that reads like a
credentials fault.

### Before pointing this at production data

Every row the agent reads is sent to Cursor's model API. Production learner data
includes phone numbers, names and email addresses. This is a data-governance
decision, not a technical one, and it should be made explicitly rather than
inherited by default. Options include restricting the grant to non-PII tables, or
providing a masked view.

---

## What is deliberately not requested

- No IAM users
- No long-lived access keys
- No write permissions in any application account
- No `ReadOnlyAccess` managed policy
- No production application resources in the agent account

Write access, when it is eventually needed for end-to-end work, belongs in a
separate `nkb-agent-sandbox` account. That keeps one invariant intact: **the
agent observes production and experiments only in a sandbox.**

---

## Summary for the ticket

| Item | Value |
| --- | --- |
| New account | `nxtwave-agent-platform-dev` |
| ECS task role | `nkb-agent-runtime-role` (agent account) |
| ECS execution role | `nkb-agent-ecs-execution-role` (agent account) |
| Cross-account role | `nkb-agent-readonly` (each workload account) |
| Secret | `nkb-agent/cursor-api-key` |
| IAM users | none |
| Access keys | none |
| DB, if in scope | IAM auth on cluster + `nkb_agent_readonly` user + reader-endpoint network path |
