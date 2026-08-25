#!/usr/bin/env bash
#
# Filesystem and environment isolation checks.
#
# Unlike the ACP policy suite, these are expected to FAIL before the sandbox
# lands. They encode the Phase 2 definition of done, and the count of open gaps
# is the number that has to reach zero. Run them from wherever the agent runs:
# on the host today, inside the container once it exists, so the same script
# measures the same thing before and after.
#
# Every check is non-destructive. Writability is probed with access(2) via
# `test -w` rather than by creating a file, because the product repositories are
# read-only and a test that dirties them would defeat its own purpose.
#
#   bash tests/security/run-isolation-tests.sh [--json <path>]
#
# Exit code is the number of open gaps.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

JSON_OUT=""
[[ "${1:-}" == "--json" ]] && JSON_OUT="${2:-}"

GAPS=0
TOTAL=0
ROWS=()

# check <name> <expectation> <"open"|"closed"> <detail>
record() {
  local name="$1" expected="$2" state="$3" detail="$4"
  TOTAL=$((TOTAL + 1))
  local mark
  if [[ "$state" == "closed" ]]; then
    mark="pass"
  else
    mark="GAP "
    GAPS=$((GAPS + 1))
  fi
  printf '  %s  %-46s %s\n' "$mark" "$name" "$detail"
  ROWS+=("{\"check\":\"$name\",\"expected\":\"$expected\",\"state\":\"$state\",\"detail\":\"$detail\"}")
}

echo
echo "Isolation checks - these define Phase 2 done"
echo

# --- product source must not be writable -------------------------------------
for repo in nkb_backend nkb_assessment_backend nkb_learning_backend; do
  target="repos/$repo"
  if [[ ! -e "$target" ]]; then
    record "$repo not present" "read-only mount" "open" "path missing entirely"
  elif [[ -w "$target" ]]; then
    record "$repo is read-only" "read-only mount" "open" "writable - a symlink to a working copy"
  else
    record "$repo is read-only" "read-only mount" "closed" "not writable"
  fi
done

# --- committed credential files must be absent from the agent's view ----------
# These are tracked in the product repositories, so a clean clone reproduces
# them; only an export filter or a mount exclusion removes them.
CRED_HITS=0
for repo in nkb_backend nkb_assessment_backend nkb_learning_backend; do
  resolved="$(readlink -f "repos/$repo" 2>/dev/null)" || continue
  [[ -d "$resolved" ]] || continue
  n=$(git -C "$resolved" ls-files 2>/dev/null \
      | grep -cE 'env_prod|service_account|\.pem$|credentials\.json$' || true)
  CRED_HITS=$((CRED_HITS + n))
done
if [[ "$CRED_HITS" -eq 0 ]]; then
  record "no committed credential files reachable" "absent from workspace" "closed" "none found"
else
  record "no committed credential files reachable" "absent from workspace" "open" \
    "$CRED_HITS tracked credential files reachable"
fi

# --- host configuration must not be reachable --------------------------------
for pair in "$HOME/.aws:host AWS config" "$HOME/.cursor:host Cursor config"; do
  path="${pair%%:*}"; label="${pair##*:}"
  if [[ -e "$path" ]]; then
    record "$label not mounted" "not present" "open" "readable at $path"
  else
    record "$label not mounted" "not present" "closed" "not present"
  fi
done

# --- the AWS CLI is an entire bypass path around MCP and ToolHive ------------
if command -v aws >/dev/null 2>&1; then
  record "aws cli absent from runtime" "not installed" "open" "on PATH at $(command -v aws)"
else
  record "aws cli absent from runtime" "not installed" "closed" "not on PATH"
fi

# --- generated context must remain writable, or investigation cannot record --
if [[ -w context && -w knowledge ]]; then
  record "generated context writable" "read-write" "closed" "context and knowledge writable"
else
  record "generated context writable" "read-write" "open" "expected writable, is not"
fi

echo
echo "  $((TOTAL - GAPS))/$TOTAL closed, $GAPS open"
echo

if [[ -n "$JSON_OUT" ]]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  {
    printf '{\n  "capturedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "total": %d,\n  "open": %d,\n  "checks": [\n' "$TOTAL" "$GAPS"
    for i in "${!ROWS[@]}"; do
      printf '    %s%s\n' "${ROWS[$i]}" "$([[ $i -lt $((${#ROWS[@]} - 1)) ]] && echo ,)"
    done
    printf '  ]\n}\n'
  } > "$JSON_OUT"
  echo "  wrote $JSON_OUT"
  echo
fi

exit "$GAPS"
