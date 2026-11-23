#!/usr/bin/env bash
# Creates ONLY net-new nkb-agent-test-* resources in the alpha account.
# Does not modify any existing VPC, RDS, SG, or subnet.
#
# Usage:
#   AWS_PROFILE=alpha bash scripts/provision-alpha-db.sh
#   AWS_PROFILE=alpha bash scripts/provision-alpha-db.sh --status
#   AWS_PROFILE=alpha bash scripts/provision-alpha-db.sh --teardown
#
# Aurora MySQL does not offer db.t4g.micro or db.t4g.small in ap-south-1.
# The smallest provisioned class with a reader is db.t4g.medium.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/_common.sh"

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
STATE="$POC_ROOT/workspace/agent-test-aws/state.env"
mkdir -p "$(dirname "$STATE")"

PREFIX=nkb-agent-test
VPC_CIDR=10.40.0.0/24
PRIV_A_CIDR=10.40.0.64/26
PRIV_B_CIDR=10.40.0.128/26
PUB_CIDR=10.40.0.0/28
ENGINE_VERSION=8.0.mysql_aurora.3.08.0
INSTANCE_CLASS=db.t4g.medium

save_state() {
  {
    echo "REGION=$AWS_DEFAULT_REGION"
    echo "PREFIX=$PREFIX"
    echo "VPC_ID=${VPC_ID:-}"
    echo "PRIV_A=${PRIV_A:-}"
    echo "PRIV_B=${PRIV_B:-}"
    echo "PUB_SUBNET=${PUB_SUBNET:-}"
    echo "DB_SG=${DB_SG:-}"
    echo "CLUSTER_ID=${PREFIX}"
  } >"$STATE"
}

load_state() {
  [[ -f "$STATE" ]] && source "$STATE"
}

status() {
  load_state
  heading "Alpha DB test stack ($AWS_DEFAULT_REGION)"
  aws sts get-caller-identity --query 'Account' --output text | xargs -I{} ok "account {}" 
  aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" \
    --query 'DBClusters[0].{Status:Status,Engine:Engine,Endpoint:Endpoint,Reader:ReaderEndpoint}' \
    --output table 2>/dev/null || dim "  cluster not found"
  aws rds describe-db-instances \
    --query "DBInstances[?contains(DBInstanceIdentifier, \`$PREFIX\`)].{Id:DBInstanceIdentifier,Class:DBInstanceClass,Status:DBInstanceStatus}" \
    --output table 2>/dev/null || true
  [[ -f "$STATE" ]] && dim "  state: $STATE"
}

teardown() {
  load_state
  heading "Teardown (nkb-agent-test only)"
  for id in "${PREFIX}-reader" "${PREFIX}-writer"; do
    if aws rds describe-db-instances --db-instance-identifier "$id" >/dev/null 2>&1; then
      dim "  deleting instance $id..."
      aws rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot >/dev/null
    fi
  done
  if aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" >/dev/null 2>&1; then
    dim "  waiting for instances..."
    aws rds wait db-instance-deleted --db-instance-identifier "${PREFIX}-writer" 2>/dev/null || true
    aws rds wait db-instance-deleted --db-instance-identifier "${PREFIX}-reader" 2>/dev/null || true
    dim "  deleting cluster..."
    aws rds delete-db-cluster --db-cluster-identifier "$PREFIX" --skip-final-snapshot >/dev/null
    aws rds wait db-cluster-deleted --db-cluster-identifier "$PREFIX"
  fi
  aws rds delete-db-subnet-group --db-subnet-group-name "${PREFIX}-subnets" 2>/dev/null || true
  ok "RDS resources removed (VPC left for manual delete if needed)"
}

provision() {
  heading "Preflight"
  acct="$(aws sts get-caller-identity --query Account --output text)"
  ok "AWS_PROFILE=${AWS_PROFILE:-default}  account $acct  region $AWS_DEFAULT_REGION"

  if aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PREFIX}-vpc" --query 'Vpcs[0].VpcId' --output text | grep -q '^vpc-'; then
    VPC_ID="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PREFIX}-vpc" --query 'Vpcs[0].VpcId' --output text)"
    ok "VPC already exists  $VPC_ID"
  else
    heading "VPC (new dedicated ${PREFIX}-vpc)"
    VPC_ID="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PREFIX}-vpc}]" \
      --query Vpc.VpcId --output text)"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support >/dev/null
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames >/dev/null
    ok "created $VPC_ID  ($VPC_CIDR)"
  fi

  AZ_A="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
  AZ_B="$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)"

  create_subnet() {
    local name="$1" cidr="$2" az="$3"
    local existing
    existing="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$name" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
    if [[ "$existing" == subnet-* ]]; then echo "$existing"; return; fi
    aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$name}]" \
      --query Subnet.SubnetId --output text
  }

  PRIV_A="$(create_subnet "${PREFIX}-private-a" "$PRIV_A_CIDR" "$AZ_A")"
  PRIV_B="$(create_subnet "${PREFIX}-private-b" "$PRIV_B_CIDR" "$AZ_B")"
  PUB_SUBNET="$(create_subnet "${PREFIX}-public" "$PUB_CIDR" "$AZ_A")"
  ok "subnets  private-a=$PRIV_A  private-b=$PRIV_B"

  if ! aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
       --query 'InternetGateways[0].InternetGatewayId' --output text | grep -q '^igw-'; then
    IGW="$(aws ec2 create-internet-gateway \
      --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PREFIX}-igw}]" \
      --query InternetGateway.InternetGatewayId --output text)"
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"
    RT="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-public-rt}]" \
      --query RouteTable.RouteTableId --output text)"
    aws ec2 create-route --route-table-id "$RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
    aws ec2 associate-route-table --route-table-id "$RT" --subnet-id "$PUB_SUBNET" >/dev/null
    ok "public route via $IGW (bastion subnet only)"
  fi

  if ! aws rds describe-db-subnet-groups --db-subnet-group-name "${PREFIX}-subnets" >/dev/null 2>&1; then
    aws rds create-db-subnet-group \
      --db-subnet-group-name "${PREFIX}-subnets" \
      --db-subnet-group-description "NKB agent test - dedicated VPC" \
      --subnet-ids "$PRIV_A" "$PRIV_B" >/dev/null
    ok "subnet group ${PREFIX}-subnets"
  fi

  DB_SG="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${PREFIX}-db-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [[ "$DB_SG" != sg-* ]]; then
    DB_SG="$(aws ec2 create-security-group --group-name "${PREFIX}-db-sg" \
      --description "NKB agent test Aurora - no inbound until client exists" \
      --vpc-id "$VPC_ID" --query GroupId --output text)"
    ok "db security group $DB_SG (no inbound rules)"
  fi

  save_state

  if ! aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" >/dev/null 2>&1; then
    heading "Aurora cluster ($INSTANCE_CLASS writer + reader)"
    dim "  smallest Aurora class in ap-south-1 — micro/small are not offered"
    aws rds create-db-cluster \
      --db-cluster-identifier "$PREFIX" \
      --engine aurora-mysql \
      --engine-version "$ENGINE_VERSION" \
      --master-username admin \
      --manage-master-user-password \
      --database-name nkb_agent_test \
      --db-subnet-group-name "${PREFIX}-subnets" \
      --vpc-security-group-ids "$DB_SG" \
      --enable-iam-database-authentication \
      --backup-retention-period 1 >/dev/null
    ok "cluster creating..."
  else
    ok "cluster already exists"
  fi

  for role in writer reader; do
    id="${PREFIX}-${role}"
    if ! aws rds describe-db-instances --db-instance-identifier "$id" >/dev/null 2>&1; then
      aws rds create-db-instance \
        --db-instance-identifier "$id" \
        --db-cluster-identifier "$PREFIX" \
        --db-instance-class "$INSTANCE_CLASS" \
        --engine aurora-mysql >/dev/null
      ok "instance $id creating..."
    fi
  done

  heading "Waiting for available (5–15 min)"
  aws rds wait db-instance-available --db-instance-identifier "${PREFIX}-writer"
  aws rds wait db-instance-available --db-instance-identifier "${PREFIX}-reader"
  aws rds wait db-cluster-available --db-cluster-identifier "$PREFIX"

  READER="$(aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" \
    --query 'DBClusters[0].ReaderEndpoint' --output text)"
  WRITER="$(aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" \
    --query 'DBClusters[0].Endpoint' --output text)"
  RESOURCE_ID="$(aws rds describe-db-clusters --db-cluster-identifier "$PREFIX" \
    --query 'DBClusters[0].DbClusterResourceId' --output text)"

  save_state
  {
    echo "READER_HOST=$READER"
    echo "WRITER_HOST=$WRITER"
    echo "CLUSTER_RESOURCE_ID=$RESOURCE_ID"
  } >>"$STATE"

  ok "writer  $WRITER"
  ok "reader  $READER"
  ok "resource id  $RESOURCE_ID"
  printf '\n  Next: bash scripts/setup-alpha-db-user.sh\n\n'
}

case "${1:-}" in
  --status) status ;;
  --teardown) teardown ;;
  *) provision ;;
esac
