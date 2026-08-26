# Alpha test database — Aurora MySQL

What to create in `nxtwave-alpha` so the database path can be proven before any
production credential exists.

**Everything here creates new resources. Nothing existing is modified.** The two
PostgreSQL instances already in alpha (`agentic-ide-db`, `n8n-testing-db`) are
untouched, as is their networking.

Confirmed by Rajesh on 2026-08-26: production is **Aurora MySQL**, a cluster with
a writer instance and a reader instance. This mirrors that topology deliberately —
the guarantee we most need to verify only exists on a reader.

---

## What this is for

Three things have to be true before the agent may read a production row, and only
the first two can be proven here:

1. The agent connects as `nkb_agent_readonly`, **not** as the master user.
2. A write is refused by the database engine, not by our code.
3. (Production only) The network path reaches the reader endpoint.

Point 2 is why this must be Aurora with a reader instance rather than a single
MySQL instance. Aurora replicas run `innodb_read_only`, so `CREATE TABLE` against
the reader fails with `ERROR 1290` even if the GRANTs were wrong and even if the
MCP server's read-only flag were bypassed. That is the strongest control in the
whole design and it costs nothing. A plain single-instance RDS MySQL has no
reader endpoint, so it cannot demonstrate it — we would finish this exercise
having proven only the weaker half.

---

## Parameters

Fill these in once; every command below refers to them.

| Name | Suggested value | Notes |
| --- | --- | --- |
| Region | `ap-south-1` | same region as the existing alpha role |
| Cluster id | `nkb-agent-test` | |
| Engine | `aurora-mysql` | |
| Engine version | `8.0.mysql_aurora.3.08.*` | must be **3.07 or higher** — see below |
| Instance class | `db.t4g.medium` | smallest Aurora class; two instances |
| Database name | `nkb_agent_test` | |
| Master user | `admin` | used only for setup, never by the agent |
| Subnet group | `nkb-agent-test-subnets` | **new**, over existing private subnets |
| Security group | `nkb-agent-test-sg` | **new**, empty until a client exists |

Version 3.07+ matters beyond parity: it is the minimum for the RDS Data API,
which is an HTTPS endpoint requiring no VPC access. Enabling it costs nothing and
keeps that option open — see "network access" below.

---

## 1. Networking (new resources only)

Reuse the existing private subnets by *referencing* them; do not modify them.

```bash
REGION=ap-south-1
VPC_ID=<vpc-id of the subnets you choose>

# A subnet group over at least two subnets in different AZs.
aws rds create-db-subnet-group \
  --db-subnet-group-name nkb-agent-test-subnets \
  --db-subnet-group-description "NKB agent test cluster" \
  --subnet-ids <subnet-a> <subnet-b> \
  --region "$REGION"

# A security group with NO inbound rules yet. Rules are added once we know
# what connects - see "network access".
aws ec2 create-security-group \
  --group-name nkb-agent-test-sg \
  --description "NKB agent test Aurora MySQL" \
  --vpc-id "$VPC_ID" \
  --region "$REGION"
```

Creating the group empty is deliberate. An unreachable database is a fixable
problem; one that was opened wider than intended tends to stay that way.

## 2. The cluster

```bash
aws rds create-db-cluster \
  --db-cluster-identifier nkb-agent-test \
  --engine aurora-mysql \
  --engine-version 8.0.mysql_aurora.3.08.0 \
  --master-username admin \
  --manage-master-user-password \
  --database-name nkb_agent_test \
  --db-subnet-group-name nkb-agent-test-subnets \
  --vpc-security-group-ids <sg-id from step 1> \
  --enable-iam-database-authentication \
  --enable-http-endpoint \
  --backup-retention-period 1 \
  --region "$REGION"
```

Three flags carry weight:

- `--enable-iam-database-authentication` is what lets the agent authenticate with
  a short-lived token instead of a stored password. Without it,
  `agent-readonly-user.sql` cannot be applied as written.
- `--enable-http-endpoint` turns on the Data API. Optional, but see below.
- `--manage-master-user-password` keeps the master password in Secrets Manager
  rather than on someone's terminal. The agent is never granted access to it.

## 3. Writer and reader

```bash
aws rds create-db-instance \
  --db-instance-identifier nkb-agent-test-writer \
  --db-cluster-identifier nkb-agent-test \
  --db-instance-class db.t4g.medium \
  --engine aurora-mysql --region "$REGION"

aws rds create-db-instance \
  --db-instance-identifier nkb-agent-test-reader \
  --db-cluster-identifier nkb-agent-test \
  --db-instance-class db.t4g.medium \
  --engine aurora-mysql --region "$REGION"
```

The reader is the point of the exercise, not an optional extra.

## 4. Confirm both endpoints exist

```bash
aws rds describe-db-cluster-endpoints \
  --db-cluster-identifier nkb-agent-test --region "$REGION" \
  --query 'DBClusterEndpoints[].{Type:EndpointType,Endpoint:Endpoint}' --output table
```

Expect two: `WRITER` and `READER`. The reader hostname contains `cluster-ro-`.
That hostname is the only one the agent is ever configured with.

Also capture the cluster resource id, needed for the IAM grant:

```bash
aws rds describe-db-clusters --db-cluster-identifier nkb-agent-test \
  --region "$REGION" --query 'DBClusters[].DbClusterResourceId' --output text
```

It looks like `cluster-ABC123…`. It is **not** the cluster name — using the name
produces an access-denied that reads like a credentials fault.

## 5. Schema, no data

Load the product table structure with empty tables. What matters is that the
agent can answer "which table stores assessment submissions" against a realistic
schema; no real rows are needed, and none should be present.

Generate from the product repos rather than hand-writing it:

```bash
# In each product repo, against a local/dev database:
python manage.py inspectdb > /dev/null   # confirms connectivity
mysqldump --no-data --skip-add-drop-table \
          -h <dev-host> -u <dev-user> -p <dev-db> > schema.sql
```

Review `schema.sql` before loading it — `--no-data` omits rows, but views and
routines can still embed literals.

## 6. The read-only user

Run [`agent-readonly-user.sql`](agent-readonly-user.sql) against the **writer**
endpoint as master. It replicates to the reader automatically.

Substitute `<DB_NAME>` with `nkb_agent_test`.

## 7. Grant the token permission

Add to the alpha `nkb-agent-readonly` role — this is the one IAM change, and it
is scoped to a single database user:

```json
{ "Sid": "DbConnectAsReadOnlyUserOnly",
  "Effect": "Allow",
  "Action": "rds-db:connect",
  "Resource": "arn:aws:rds-db:ap-south-1:<ACCT>:dbuser:<CLUSTER_RESOURCE_ID>/nkb_agent_readonly" }
```

It grants the ability to *authenticate* as that one user. What that user may then
read is decided by the GRANTs in step 6, not by IAM.

---

## Network access — the open decision

The cluster will sit in private subnets and be unreachable from a laptop, exactly
like the two existing alpha instances. One of these has to be true before
anything can be tested:

| Option | What it needs | Trade-off |
| --- | --- | --- |
| **EC2/ECS in the same VPC** | one small instance, SG rule from its SG | matches the production design exactly; most representative |
| **VPN** | VPN access for the developer | convenient, no extra infrastructure |
| **Data API** | `--enable-http-endpoint`, already set above | no network path at all, but **no reader routing** — loses the `ERROR 1290` guarantee |
| ~~Public + IP allowlist~~ | — | not recommended even for test data; the habit is the risk |

These are not mutually exclusive, and the useful combination is the first or
second **plus** the third. The Data API can prove the query path today with no
networking work at all; the VPC path is what proves the reader guarantee. Doing
both means neither question waits on the other.

---

## Verification

Both halves matter. A passing read proves the plumbing; a refused write proves
the boundary.

Connect to the **reader** endpoint as `nkb_agent_readonly`:

```sql
SHOW GRANTS FOR 'nkb_agent_readonly'@'%';
-- expect exactly one GRANT SELECT line, plus USAGE. Anything more is too much.

SELECT COUNT(*) FROM <some_table>;        -- expect: succeeds (0 rows is fine)
CREATE TABLE _agent_write_probe (x INT);  -- expect: ERROR 1290 ... --read-only
INSERT INTO <some_table> VALUES (...);    -- expect: refused
SELECT * FROM mysql.user;                 -- expect: refused, no grant
```

The `ERROR 1290` is the result worth capturing. It is the engine refusing,
independent of grants, independent of our code.

---

## Teardown

This is a test cluster. Two `db.t4g.medium` instances left running cost real
money for no benefit once the path is proven.

```bash
aws rds delete-db-instance --db-instance-identifier nkb-agent-test-reader \
  --skip-final-snapshot --region "$REGION"
aws rds delete-db-instance --db-instance-identifier nkb-agent-test-writer \
  --skip-final-snapshot --region "$REGION"
aws rds delete-db-cluster --db-cluster-identifier nkb-agent-test \
  --skip-final-snapshot --region "$REGION"
```

Set a billing alarm on the alpha account first if there is not one already.

---

## What production will need, once this passes

Deliberately short, because the point of doing this in alpha is to make the
production ask small and specific:

- `rds-db:connect` on the `nkb_agent_readonly` dbuser ARN — one statement.
- `agent-readonly-user.sql` run once against the production writer.
- A network path from the agent's VPC to the **reader** endpoint.
- Nothing else. No master secret, no write permission, no Secrets Manager access.
