# Database access

IAM read permissions do not grant SQL access. `rds:DescribeDBInstances` returns
*metadata about* a database — engine, version, endpoint, whether it is encrypted. It
says nothing about the rows inside, and no IAM action grants that. Reading data needs
three separate things, and the agent currently has none of them:

1. A database user with `SELECT` grants — a database-level identity, not an AWS one.
2. A network path to the endpoint. RDS lives in a VPC; IAM does not create routes.
3. An MCP server that speaks SQL.

The permissions in `provisioning/iam/agent-readonly-permissions.json` cover only step
zero: discovering that a database exists.

## What is in the alpha account

Checked 2026-08-25 as `nkb-agent-readonly-alpha`:

| Instance | Engine | Public | IAM auth | VPC |
| --- | --- | --- | --- | --- |
| `agentic-ide-db` | postgres 16.13 | no | disabled | `vpc-04fb7530977c81aea` |
| `n8n-testing-db` | postgres 13.23 | no | disabled | `vpc-0896389ce506313be` |

Zero Aurora clusters, which rules out the RDS Data API — it is Aurora-only, and it was
the one option that needs no network path.

Three consequences. Both instances are in private subnets, so nothing is reachable
without VPN or in-VPC deployment; a TCP probe to `agentic-ide-db:5432` confirms this.
Both are PostgreSQL while the product runs **MySQL** (`django.db.backends.mysql`),
so neither could validate a product query path anyway. And neither is a product
database — they belong to unrelated tooling.

There is nothing in alpha to test against.

## Why no SQL server is attached

Beyond having nothing to connect to, `awslabs.mysql-mcp-server` is the obvious
candidate and is the wrong tool for this design. Its `--help` output lists no
credential option at all:

```
--connection_method  RDS_API | MYSQL_WIRE_PROTOCOL | MYSQL_WIRE_IAM_PROTOCOL
--db_cluster_arn  --db_type  --db_endpoint  --region
--allow_write_query  --database  --port  --ca_bundle
```

Credentials are derived from the cluster's managed `MasterUserSecret`, or via IAM auth
as the cluster's `MasterUsername`. Every path connects as **master**.

That inverts the design. `provisioning/db/agent-readonly-user.sql` creates a
`SELECT`-only user precisely so the database itself constrains the agent, and this
server cannot use it. Worse, deriving the master secret requires granting the agent
`secretsmanager:GetSecretValue` on it — so an agent meant to hold read-only access
would hold the master database password. That is a privilege escalation, not an
integration, and it is not being added silently.

One point in its favour: `--allow_write_query` is a flag rather than a value, so
omitting it is read-only. The default is safe.

## What is implemented and verified

Statement-level gating, under `mcp.sqlQuery` in `config/acp-permissions.json` and
enforced by `evaluateSql()` in the shim. `runtime/mcp/sql-probe.mjs` is a stub
exposing the same shape a real SQL tool has — one `run_query` taking `sql` — so the
gating can be exercised without a database. Tested end-to-end:

| Statement | Outcome |
| --- | --- |
| `SELECT id, created_at FROM users LIMIT 5` | permitted, reached the stub |
| `DROP TABLE users` | blocked, DDL keyword |
| `SELECT 1; DROP TABLE users` | blocked, DDL keyword in the second statement |
| `SELECT * FROM users INTO OUTFILE '/tmp/x.csv'` | blocked, exfiltration |
| `SELECT /* harmless */ -- x`<br>`password_hash FROM mysql.user` | blocked, credential table |

The last case matters most: comments are stripped before the keyword is read, so
hiding intent behind `/* */` or `--` does not work.

This gating is a layer, not the control. The controls that matter are a `SELECT`-only
database user and an Aurora reader endpoint, which runs `innodb_read_only` and refuses
writes at the engine whatever the grants say. If this shim is the only thing between an
agent and a database, the database is configured wrong.

## To finish this

- **A network path.** Either run the agent inside the VPC — which is the deployed ECS
  design and needs nothing extra — or connect the VPN for local work. Do not make an
  instance publicly accessible for it.
- **A MySQL server that accepts an explicit user.** Needed to use
  `nkb_agent_readonly` rather than master. A community server would put production
  database credentials behind third-party code, so it warrants review before adoption;
  a thin server of our own is a credible alternative given the surface is one method.
- **A test database first.** A MySQL instance in alpha with the schema and no real
  data would let the whole path be proven before any production credential exists.

Worth deciding early, separately: every row returned is transmitted to an external
model API. If learner PII must not leave the VPC, grant against masked views instead
of base tables — there is a sketch at the end of
`provisioning/db/agent-readonly-user.sql`.
