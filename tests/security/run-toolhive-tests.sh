#!/usr/bin/env bash
#
# Proves ToolHive actually enforces MCP tool admission.
#
# This suite is the precondition for deleting the mcp.allowedServers and
# mcp.gatedTools logic from the shim. Section 7 of the migration plan says a
# protection is only removed once its replacement has been tested against the
# same abuse cases, and "ToolHive has a --tools flag" is not evidence that the
# flag is enforced.
#
# The distinction that matters: hiding a tool from tools/list is cosmetic on its
# own, because a client that already knows the name can call it anyway. So every
# excluded tool is checked twice - absent from the listing, AND refused when
# called directly. The second check is the security property.
#
#   bash tests/security/run-toolhive-tests.sh [--json <path>]
#
# Needs the gateway running: bash scripts/toolhive-up.sh
# Exit code is the number of failures.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

export XDG_CONFIG_HOME="$ROOT/runtime/toolhive/config"
export XDG_DATA_HOME="$ROOT/runtime/toolhive/data"
export XDG_STATE_HOME="$ROOT/runtime/toolhive/state"
THV="$ROOT/runtime/toolhive/bin/thv"

JSON_OUT=""
[[ "${1:-}" == "--json" ]] && JSON_OUT="${2:?--json needs a path}"

SERVER=gw-awsdocs
ALLOWED=(search_documentation read_documentation)
EXCLUDED=(read_sections recommend search_table)

FAILURES=0
TOTAL=0
ROWS=()

record() {
  local state="$1" name="$2" detail="$3"
  TOTAL=$((TOTAL + 1))
  local mark="pass"
  if [[ "$state" != "pass" ]]; then mark="FAIL"; FAILURES=$((FAILURES + 1)); fi
  printf '  %s  %-52s %s\n' "$mark" "$name" "$detail"
  ROWS+=("{\"check\":\"$name\",\"state\":\"$state\",\"detail\":\"${detail//\"/}\"}")
}

echo
[[ -x "$THV" ]] || { echo "  thv not installed at $THV" >&2; exit 1; }

if ! "$THV" list 2>/dev/null | grep -q "$SERVER.*running"; then
  echo "  gateway not running - start it with: bash scripts/toolhive-up.sh" >&2
  exit 1
fi

echo "ToolHive MCP admission - gateway $SERVER"
echo

# --- tools/list must advertise exactly the allowlist -------------------------
LISTED="$("$THV" mcp list tools --server "$SERVER" 2>&1)"

for tool in "${ALLOWED[@]}"; do
  if grep -qE "^${tool}[[:space:]]" <<<"$LISTED" || grep -qE "^  ${tool}[[:space:]]" <<<"$LISTED"; then
    record pass "allowlisted tool advertised: $tool" "present in tools/list"
  else
    record fail "allowlisted tool advertised: $tool" "MISSING - the gateway is over-filtering"
  fi
done

for tool in "${EXCLUDED[@]}"; do
  # Anchored: tool names appear inside other tools' description text, so a bare
  # substring match reports false failures.
  if grep -qE "^${tool}[[:space:]]" <<<"$LISTED"; then
    record fail "excluded tool hidden: $tool" "ADVERTISED - filter not applied"
  else
    record pass "excluded tool hidden: $tool" "absent from tools/list"
  fi
done

# --- tools/call is the check that actually matters ---------------------------
#
# A client that knows a tool name does not need it listed. If the call succeeds
# the filter is decoration.

for tool in "${EXCLUDED[@]}"; do
  OUT="$(timeout 90 "$THV" mcp call "$tool" --server "$SERVER" --args '{}' 2>&1)"
  if grep -qiE 'tool not found|not allowed|forbidden|unauthorized|unknown tool' <<<"$OUT"; then
    record pass "excluded tool refused on call: $tool" "gateway refused: tool not found"
  elif grep -qiE 'error|invalid|required' <<<"$OUT"; then
    # Reached the server and failed on arguments: the gateway let it through.
    record fail "excluded tool refused on call: $tool" "REACHED SERVER - only argument validation stopped it"
  else
    record fail "excluded tool refused on call: $tool" "CALL SUCCEEDED - filter is not enforced"
  fi
done

# --- an allowlisted tool must still work, or we have broken the platform -----
OUT="$(timeout 120 "$THV" mcp call search_documentation --server "$SERVER" \
        --args '{"search_phrase":"S3 bucket versioning","search_intent":"regression test","limit":1}' 2>&1)"
if grep -qE 'search_results|rank_order' <<<"$OUT"; then
  record pass "allowlisted tool callable" "returned results through the gateway"
else
  record fail "allowlisted tool callable" "call failed: $(head -c 90 <<<"$OUT")"
fi

# --- calls must be auditable, or there is no evidence trail ------------------
AUDIT_LOG="$XDG_DATA_HOME/toolhive/logs/$SERVER.log"
if [[ -f "$AUDIT_LOG" ]] && grep -q '"type":"mcp_tool_call"' "$AUDIT_LOG"; then
  N=$(grep -c '"type":"mcp_tool_call"' "$AUDIT_LOG")
  record pass "tool calls audited" "$N mcp_tool_call events with id, subject and outcome"
else
  record fail "tool calls audited" "no mcp_tool_call events found"
fi

# --- the sandbox must be able to reach the gateway --------------------------
#
# Without this the governed path is unusable from where the agent runs, and
# Cursor would fall back to spawning its own ungoverned MCP servers.
IMAGE="${NKB_AGENT_IMAGE:-nkb-agent-runtime:2026.08.11-e8db854}"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  PORT=$(grep -E '^\s+proxy_port:' config/toolhive/servers.yaml | head -1 | grep -oE '[0-9]+')
  CODE="$(timeout 90 docker run --rm --add-host=host.docker.internal:host-gateway \
            --entrypoint /bin/bash "$IMAGE" -c \
            "curl -s -m 10 -o /dev/null -w '%{http_code}' http://host.docker.internal:${PORT:-19103}/mcp 2>/dev/null" 2>/dev/null)"
  if [[ -n "$CODE" && "$CODE" != "000" ]]; then
    record pass "sandbox can reach the gateway" "HTTP $CODE via host.docker.internal"
  else
    record fail "sandbox can reach the gateway" "no response - agent could not use governed MCP"
  fi
else
  record fail "sandbox can reach the gateway" "sandbox image not built"
fi

echo
echo "  $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed"
echo

if [[ -n "$JSON_OUT" ]]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  {
    printf '{\n  "capturedAt": "%s",\n  "toolhive": "%s",\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$("$THV" version 2>/dev/null | head -1)"
    printf '  "total": %d,\n  "failures": %d,\n  "checks": [\n' "$TOTAL" "$FAILURES"
    for i in "${!ROWS[@]}"; do
      printf '    %s%s\n' "${ROWS[$i]}" "$([[ $i -lt $((${#ROWS[@]} - 1)) ]] && echo ,)"
    done
    printf '  ]\n}\n'
  } > "$JSON_OUT"
  echo "  wrote $JSON_OUT"
  echo
fi

exit "$FAILURES"
