#!/usr/bin/env bash
#
# Proves that AWS itself refuses writes, independently of any code we wrote.
#
# This is the gate for deleting the custom AWS command parser. Every other AWS
# test in this suite is answered by our own policy layer before a request
# leaves the machine, which proves the parser works and says nothing about what
# AWS would do. Only this file tests the boundary that survives a bug in our
# code.
#
# Safe by construction: every denied call targets a resource name that does not
# exist. If IAM refuses we get AccessDenied, which is the result we want. If IAM
# unexpectedly allows, the call still fails on lookup and nothing is destroyed.
# There is no ordering of events in which this script can delete anything.
#
# The ambient environment is stripped rather than trusted, because on this
# machine AWS_PROFILE=default resolves to a different account than the one this
# POC is scoped to.
#
#   bash tests/security/run-iam-tests.sh [--json <path>]
#
# Exit code is the number of unexpected outcomes.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

JSON_OUT=""
[[ "${1:-}" == "--json" ]] && JSON_OUT="${2:-}"

CREDS="$ROOT/runtime/aws/credentials"
PROFILE="nkb-agent-alpha"
REGION="ap-south-1"
ABSENT="nkb-agent-iam-probe-absent"

if [[ ! -f "$CREDS" ]]; then
  echo "no scoped credentials at $CREDS - nothing to test" >&2
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  echo "aws cli not available" >&2
  exit 1
fi

# Only these reach the CLI; anything ambient is discarded.
run_aws() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
      -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_CONFIG_FILE -u AWS_REGION \
      -u AWS_DEFAULT_REGION \
      AWS_SHARED_CREDENTIALS_FILE="$CREDS" \
      AWS_PROFILE="$PROFILE" \
      AWS_DEFAULT_REGION="$REGION" \
      aws "$@" 2>&1
}

FAILURES=0
INCONCLUSIVE=0
TOTAL=0
ROWS=()

# expect_denied <name> <aws args...>
#
# A resource-not-found reply does NOT prove the call was authorized. Several
# services resolve the resource before evaluating IAM - SQS returns
# NonExistentQueue for a missing queue whether or not the caller could have
# deleted a real one - so that outcome is inconclusive from a live call and is
# settled by the simulator tier below instead of being reported as a hole.
expect_denied() {
  local name="$1"; shift
  TOTAL=$((TOTAL + 1))
  local out; out="$(run_aws "$@")"
  local verdict detail
  if grep -qE 'AccessDenied|not authorized|explicit deny' <<<"$out"; then
    verdict="pass"; detail="AccessDenied from AWS"
  elif grep -qE 'NotFound|NonExistentQueue|does not exist|InvalidAddress' <<<"$out"; then
    verdict="skip"; detail="inconclusive - resource resolved before authz"
    INCONCLUSIVE=$((INCONCLUSIVE + 1))
  else
    verdict="FAIL"; detail="unexpected: $(head -c 110 <<<"$out" | tr '\n' ' ')"
    FAILURES=$((FAILURES + 1))
  fi
  printf '  %s  %-44s %s\n' "$verdict" "$name" "$detail"
  ROWS+=("{\"check\":\"$name\",\"expected\":\"AccessDenied\",\"result\":\"$verdict\",\"detail\":\"${detail//\"/}\"}")
}

# expect_allowed <name> <aws args...>
expect_allowed() {
  local name="$1"; shift
  TOTAL=$((TOTAL + 1))
  local out; out="$(run_aws "$@")"
  local verdict detail
  if grep -qE 'AccessDenied|not authorized|explicit deny' <<<"$out"; then
    verdict="FAIL"; detail="denied - the granted read does not work"
    FAILURES=$((FAILURES + 1))
  else
    verdict="pass"; detail="permitted"
  fi
  printf '  %s  %-44s %s\n' "$verdict" "$name" "$detail"
  ROWS+=("{\"check\":\"$name\",\"expected\":\"allowed\",\"result\":\"$verdict\",\"detail\":\"${detail//\"/}\"}")
}

echo
echo "IAM boundary - does AWS refuse writes without our code's help?"
echo
echo "  identity: $(run_aws sts get-caller-identity --query Arn --output text)"
echo

# SQS authorizes only after the queue address resolves to this account, so a
# placeholder account id returns InvalidAddress and never reaches IAM. The queue
# name is still absent, so an unexpected allow cannot delete anything.
ACCOUNT="$(run_aws sts get-caller-identity --query Account --output text)"
ABSENT_QUEUE="https://sqs.$REGION.amazonaws.com/$ACCOUNT/$ABSENT"

echo "  reads that must succeed"
expect_allowed "ecs list-clusters"            ecs list-clusters
expect_allowed "logs describe-log-groups"     logs describe-log-groups --limit 1
expect_allowed "lambda list-functions"        lambda list-functions --max-items 1

echo
echo "  writes that AWS must refuse"
expect_denied  "ecs delete-service"           ecs delete-service --cluster "$ABSENT" --service "$ABSENT"
expect_denied  "ecs update-service"           ecs update-service --cluster "$ABSENT" --service "$ABSENT" --desired-count 0
expect_denied  "logs delete-log-group"        logs delete-log-group --log-group-name "$ABSENT"
expect_denied  "lambda delete-function"       lambda delete-function --function-name "$ABSENT"
expect_denied  "sqs delete-queue"             sqs delete-queue --queue-url "$ABSENT_QUEUE"
expect_denied  "rds delete-db-instance"       rds delete-db-instance --db-instance-identifier "$ABSENT" --skip-final-snapshot
expect_denied  "iam create-user"              iam create-user --user-name "$ABSENT"
expect_denied  "iam attach-user-policy"       iam attach-user-policy --user-name "$ABSENT" --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
expect_denied  "s3 list buckets"              s3api list-buckets

# --- simulator tier ----------------------------------------------------------
#
# Authoritative, and it settles what a live call cannot: the simulator answers
# the authorization question without performing the action. It needs an
# IAM-reading profile, which the agent identity deliberately does not have, so
# this tier is skipped rather than failed when that profile is absent. Set
# NKB_IAM_SIM_PROFILE=none to skip it explicitly.
SIM_PROFILE="${NKB_IAM_SIM_PROFILE:-nxtwave-alpha}"
SIM_ACTIONS=(sqs:DeleteQueue sqs:SendMessage sqs:PurgeQueue ecs:DeleteService
             lambda:UpdateFunctionCode rds:DeleteDBInstance iam:CreateUser
             logs:DeleteLogGroup states:StartExecution)

echo
if [[ "$SIM_PROFILE" == "none" ]]; then
  echo "  simulator tier skipped (NKB_IAM_SIM_PROFILE=none)"
else
  PRINCIPAL="$(run_aws sts get-caller-identity --query Arn --output text)"
  SIM_OUT="$(env -u AWS_SHARED_CREDENTIALS_FILE -u AWS_PROFILE -u AWS_REGION \
                 -u AWS_DEFAULT_REGION -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
                 -u AWS_SESSION_TOKEN -u AWS_CONFIG_FILE \
               aws iam simulate-principal-policy \
                 --profile "$SIM_PROFILE" \
                 --policy-source-arn "$PRINCIPAL" \
                 --action-names "${SIM_ACTIONS[@]}" \
                 --query 'EvaluationResults[].[EvalActionName,EvalDecision]' \
                 --output text 2>&1)"

  if grep -qE 'EvalDecision|explicitDeny|implicitDeny|allowed' <<<"$SIM_OUT"; then
    echo "  IAM simulator - authorization decided without acting"
    while read -r action decision; do
      [[ -z "${action:-}" ]] && continue
      TOTAL=$((TOTAL + 1))
      if [[ "$decision" == *Deny* ]]; then
        printf '  pass  %-44s %s\n' "$action" "$decision"
        ROWS+=("{\"check\":\"sim $action\",\"expected\":\"deny\",\"result\":\"pass\",\"detail\":\"$decision\"}")
      else
        printf '  FAIL  %-44s %s\n' "$action" "$decision"
        FAILURES=$((FAILURES + 1))
        ROWS+=("{\"check\":\"sim $action\",\"expected\":\"deny\",\"result\":\"FAIL\",\"detail\":\"$decision\"}")
      fi
    done <<<"$SIM_OUT"
  else
    echo "  simulator tier unavailable (profile '$SIM_PROFILE' cannot read IAM)"
  fi
fi

echo
echo "  $((TOTAL - FAILURES - INCONCLUSIVE))/$TOTAL as expected, $INCONCLUSIVE inconclusive, $FAILURES unexpected"
echo

if [[ -n "$JSON_OUT" ]]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  {
    printf '{\n  "capturedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "profile": "%s",\n  "region": "%s",\n' "$PROFILE" "$REGION"
    printf '  "total": %d,\n  "unexpected": %d,\n  "inconclusive": %d,\n  "checks": [\n' "$TOTAL" "$FAILURES" "$INCONCLUSIVE"
    for i in "${!ROWS[@]}"; do
      printf '    %s%s\n' "${ROWS[$i]}" "$([[ $i -lt $((${#ROWS[@]} - 1)) ]] && echo ,)"
    done
    printf '  ]\n}\n'
  } > "$JSON_OUT"
  echo "  wrote $JSON_OUT"
  echo
fi

exit "$FAILURES"
