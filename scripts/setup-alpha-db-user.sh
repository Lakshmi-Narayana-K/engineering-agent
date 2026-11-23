#!/usr/bin/env bash
# Creates read-only DB user on the alpha test cluster via an SSM bastion in the
# dedicated VPC. Touches only nkb-agent-test-* resources.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/_common.sh"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
STATE="$POC_ROOT/workspace/agent-test-aws/state.env"
[[ -f "$STATE" ]] || { bad "run scripts/provision-alpha-db.sh first"; exit 1; }
source "$STATE"

PREFIX=nkb-agent-test
WRITER_HOST="${WRITER_HOST:-$(aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" --query 'DBClusters[0].Endpoint' --output text)}"
READER_HOST="${READER_HOST:-$(aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" --query 'DBClusters[0].ReaderEndpoint' --output text)}"
RESOURCE_ID="${CLUSTER_RESOURCE_ID:-$(aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" --query 'DBClusters[0].DbClusterResourceId' --output text)}"
SECRET_ARN="$(aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)"

heading "Bastion (t4g.micro, SSM only)"
BASTION_SG="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PREFIX}-bastion-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [[ "$BASTION_SG" != sg-* ]]; then
  BASTION_SG="$(aws ec2 create-security-group --group-name "${PREFIX}-bastion-sg" \
    --description "SSM bastion for DB setup only" --vpc-id "$VPC_ID" --query GroupId --output text)"
  ok "bastion sg $BASTION_SG"
fi

aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --protocol tcp --port 3306 \
  --source-group "$BASTION_SG" 2>/dev/null || true

ROLE_NAME="${PREFIX}-bastion-role"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name secrets-read \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":[\"$SECRET_ARN\"]}]}"
  ok "IAM role $ROLE_NAME"
fi

PROFILE_NAME="${PREFIX}-bastion-profile"
aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" 2>/dev/null || true
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
sleep 5

BASTION_ID="$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${PREFIX}-bastion" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
if [[ "$BASTION_ID" != i-* ]]; then
  AMI="$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
    --query 'Parameters[0].Value' --output text)"
  BASTION_ID="$(aws ec2 run-instances --image-id "$AMI" --instance-type t4g.micro \
    --subnet-id "$PUB_SUBNET" --security-group-ids "$BASTION_SG" \
    --iam-instance-profile Name="$PROFILE_NAME" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PREFIX}-bastion}]" \
    --query 'Instances[0].InstanceId' --output text)"
  ok "bastion $BASTION_ID launching..."
  aws ec2 wait instance-running --instance-ids "$BASTION_ID"
  dim "  waiting for SSM agent..."
  sleep 45
fi

SQL_B64="$(python3 - <<'PY' | base64 -w0
print("""CREATE TABLE IF NOT EXISTS probe_users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(64) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT IGNORE INTO probe_users (id, name) VALUES (1, 'alpha-probe');
CREATE USER IF NOT EXISTS 'nkb_agent_readonly'@'%'
  IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS' REQUIRE SSL;
GRANT SELECT ON nkb_agent_test.* TO 'nkb_agent_readonly'@'%';
ALTER USER 'nkb_agent_readonly'@'%'
  WITH MAX_USER_CONNECTIONS 5 MAX_QUERIES_PER_HOUR 2000;
FLUSH PRIVILEGES;
""")
PY
)"

heading "Schema + read-only user on writer"
REMOTE="set -e
dnf install -y mariadb105 jq
PW=\$(aws secretsmanager get-secret-value --secret-id '$SECRET_ARN' --query SecretString --output text | jq -r .password)
echo '$SQL_B64' | base64 -d > /tmp/setup.sql
mysql --host='$WRITER_HOST' --port=3306 --user=admin --password=\"\$PW\" --ssl-mode=REQUIRED nkb_agent_test < /tmp/setup.sql
echo OK"

CMD_ID="$(aws ssm send-command --instance-ids "$BASTION_ID" \
  --document-name AWS-RunShellScript \
  --parameters "commands=$REMOTE" \
  --query Command.CommandId --output text)"

dim "  SSM command $CMD_ID..."
for i in $(seq 1 40); do
  st="$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$BASTION_ID" --query Status --output text 2>/dev/null || echo Pending)"
  [[ "$st" == "Success" ]] && break
  if [[ "$st" == "Failed" || "$st" == "Cancelled" ]]; then
    aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$BASTION_ID" --output json
    exit 1
  fi
  sleep 5
done
ok "nkb_agent_readonly created"

python3 - <<PY
import pathlib, re
reader = "$READER_HOST"
p = pathlib.Path("$POC_ROOT/config/dbhub.toml")
p.write_text(re.sub(r'^host\s*=\s*"[^"]*"', f'host = "{reader}"', p.read_text(), count=1, flags=re.M))
j = pathlib.Path("$POC_ROOT/config/toolhive/db-permissions.json")
j.write_text(j.read_text().replace(
  "<CLUSTER>.cluster-ro-<SUFFIX>.ap-south-1.rds.amazonaws.com", reader))
print("  config patched")
PY

{
  echo "BASTION_ID=$BASTION_ID"
  echo "READER_HOST=$READER_HOST"
  echo "WRITER_HOST=$WRITER_HOST"
  echo "CLUSTER_RESOURCE_ID=$RESOURCE_ID"
} >>"$STATE"

ACCT="$(aws sts get-caller-identity --query Account --output text)"
printf '\n'
ok "reader  $READER_HOST"
ok "resource id  $RESOURCE_ID"
dim "  attach rds-db:connect for arn:aws:rds-db:ap-south-1:${ACCT}:dbuser:${RESOURCE_ID}/nkb_agent_readonly"
printf '\n'
