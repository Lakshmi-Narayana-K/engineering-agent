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


| Name                | Suggested value           | Notes                                                     |
| ------------------- | ------------------------- | --------------------------------------------------------- |
| Region              | `ap-south-1`              | same region as the existing alpha role                    |
| VPC                 | `nkb-agent-test-vpc`      | **new dedicated VPC** — see sizing below                  |
| CIDR                | `10.40.0.0/24`            | must not overlap any existing alpha VPC                   |
| Cluster id          | `nkb-agent-test`          |                                                           |
| Engine              | `aurora-mysql`            |                                                           |
| Engine version      | `8.0.mysql_aurora.3.08.*` | must be **3.07 or higher** — see below                    |
| Instance class      | `db.t4g.medium`           | smallest provisioned Aurora class that supports a reader  |
| Database name       | `nkb_agent_test`          |                                                           |
| Master user         | `admin`                   | used only for setup, never by the agent                   |
| Subnet group        | `nkb-agent-test-subnets`  | **new**, over the new VPC's private subnets               |
| Security group      | `nkb-agent-test-sg`       | **new**, empty until a client exists                      |
| Test EC2 (optional) | `t4g.micro`               | only if you need in-VPC wire-protocol tests from a laptop |


Version 3.07+ matters beyond parity: it is the minimum for the RDS Data API,
which is an HTTPS endpoint requiring no VPC access. Enabling it costs nothing and
keeps that option open — see "network access" below.

### Sizing and cost (test only)


| Resource      | Recommendation              | Rough cost                |
| ------------- | --------------------------- | ------------------------- |
| Aurora writer | `db.t4g.medium`             | ~55–65/mo                 |
| Aurora reader | `db.t4g.medium`             | ~55–65/mo                 |
| Dedicated VPC | `/24`, 2 private subnets    | free                      |
| NAT Gateway   | **skip for now**            | ~32/mo + traffic if added |
| Test EC2      | `t4g.micro`, only if needed | ~6/mo while running       |


**Use a new VPC, not an existing one.** The two PostgreSQL instances already in
alpha live in other VPCs with their own security groups and routing. Putting a
test cluster there couples you to networking you did not design, makes teardown
ambiguous ("is this SG shared?"), and increases the chance of opening something
wider than intended. A dedicated `nkb-agent-test-vpc` is isolated, documents
exactly what the agent needs, and deletes cleanly.

Keep the VPC **minimal**:

```
10.40.0.0/24   nkb-agent-test-vpc
├── 10.40.1.0/26   private-a  (ap-south-1a)  ← RDS subnet group
├── 10.40.2.0/26   private-b  (ap-south-1b)  ← RDS subnet group
└── 10.40.0.0/28   public     (ap-south-1a)  ← optional, bastion only
```

No NAT Gateway until you know you need outbound from a private EC2. For the
first tests, either use the **Data API** (no VPC path) or a **tiny public
bastion** (`t4g.micro`) with SSH restricted to your office IP — not `0.0.0.0/0`.

You cannot go smaller than `db.t4g.medium` on provisioned Aurora and still add a
reader. That is the smallest class that mirrors production topology. If cost is
tight, create the **writer first**, load schema, then add the **reader** only
when you are ready to run `tests/security/run-db-tests.sh` — but do not skip
the reader before claiming Phase 7 is proven.

Set a billing alarm on the alpha account and run the teardown commands when done.

---

## 1. Dedicated VPC (new — does not touch existing alpha VPCs)

Pick a `/24` that does not overlap anything already in alpha. Adjust CIDRs if
`10.40.0.0/24` conflicts.

```bash
REGION=ap-south-1
VPC_CIDR=10.40.0.0/24
PRIV_A_CIDR=10.40.1.0/26
PRIV_B_CIDR=10.40.2.0/26
PUB_CIDR=10.40.0.0/28   # optional bastion subnet

VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$REGION" \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=nkb-agent-test-vpc}]' \
  --query Vpc.VpcId --output text)

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames

# Two AZs — Aurora requires subnets in at least two AZs.
AZ_A=$(aws ec2 describe-availability-zones --region "$REGION" \
  --query 'AvailabilityZones[0].ZoneName' --output text)
AZ_B=$(aws ec2 describe-availability-zones --region "$REGION" \
  --query 'AvailabilityZones[1].ZoneName' --output text)

PRIV_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIV_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=nkb-agent-test-private-a}]' \
  --query Subnet.SubnetId --output text)
PRIV_B=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIV_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=nkb-agent-test-private-b}]' \
  --query Subnet.SubnetId --output text)

# Optional: tiny public subnet for a bastion only. Skip if you will use Data API first.
PUB_SUBNET=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUB_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=nkb-agent-test-public}]' \
  --query Subnet.SubnetId --output text)
IGW=$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=nkb-agent-test-igw}]' \
  --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"
RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=nkb-agent-test-public-rt}]' \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id "$RT" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW"
aws ec2 associate-route-table --route-table-id "$RT" --subnet-id "$PUB_SUBNET"

# RDS subnet group — private subnets only.
aws rds create-db-subnet-group \
  --db-subnet-group-name nkb-agent-test-subnets \
  --db-subnet-group-description "NKB agent test cluster" \
  --subnet-ids "$PRIV_A" "$PRIV_B" \
  --region "$REGION"

# Security group with NO inbound rules yet.
DB_SG=$(aws ec2 create-security-group \
  --group-name nkb-agent-test-sg \
  --description "NKB agent test Aurora MySQL" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --query GroupId --output text)

echo "VPC=$VPC_ID  PRIV_A=$PRIV_A  PRIV_B=$PRIV_B  DB_SG=$DB_SG"
```

Creating the database security group empty is deliberate. An unreachable database
is a fixable problem; one that was opened wider than intended tends to stay that way.

### Optional: tiny bastion for wire-protocol tests

Only if you need to run `mysql` or the agent stack from inside the VPC. Restrict
SSH to your IP, not the internet.

```bash
BASTION_SG=$(aws ec2 create-security-group --group-name nkb-agent-test-bastion-sg \
  --description "Bastion SSH from office only" --vpc-id "$VPC_ID" --region "$REGION" \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG" --protocol tcp \
  --port 22 --cidr <YOUR_OFFICE_IP>/32

# Allow the bastion to reach the database on 3306 only.
aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --protocol tcp --port 3306 \
  --source-group "$BASTION_SG"

aws ec2 run-instances --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --instance-type t4g.micro --subnet-id "$PUB_SUBNET" \
  --security-group-ids "$BASTION_SG" \
  --iam-instance-profile Name=<profile-with-SSM-if-you-prefer-no-SSH-key> \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=nkb-agent-test-bastion}]'
```

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
  --vpc-security-group-ids "$DB_SG" \
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
  v \
  --engine aurora-mysql --region "$REGION"

aws rds create-db-instance \
  --db-instance-identifier nkb-agent-test-reader \
  --db-cluster-identifier nkb-agent-test \
  zxxxxx \
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

Run `[agent-readonly-user.sql](agent-readonly-user.sql)` against the **writer**
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


| Option                      | What it needs                               | Trade-off                                                                            |
| --------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------ |
| **EC2/ECS in the same VPC** | one small instance, SG rule from its SG     | matches the production design exactly; most representative                           |
| **VPN**                     | VPN access for the developer                | convenient, no extra infrastructure                                                  |
| **Data API**                | `--enable-http-endpoint`, already set above | no network path at all, but **no reader routing** — loses the `ERROR 1290` guarantee |
| ~~Public + IP allowlist~~   | —                                           | not recommended even for test data; the habit is the risk                            |


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

