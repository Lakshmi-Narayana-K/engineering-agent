#!/usr/bin/env bash
#
# Proves the Rapid7 MCP server is safe to expose, and keeps proving it.
#
# Rapid7 is the sharpest case for section 33's warning that a tool is not
# read-only just because its name says investigate, report, search or analyze.
# In this server that is not hypothetical: of 97 tools, 64 are annotated
# readOnlyHint, 11 are annotated destructive, and 22 carry no annotation at all
# - and every one of those 22 mutates. investigate_alerts creates an
# investigation. generate_alert_report writes an artefact. Both would pass any
# name-based filter.
#
# So this suite checks two different things, and the first is unusual:
#
#   STATIC  - re-derives the read-only set from the upstream source and fails if
#             the configured allowlist contains anything outside it. This runs
#             without a gateway, and it is what stops a future edit from quietly
#             adding a mutating tool. It also catches an upstream version bump
#             that changes an annotation.
#
#   RUNTIME - the usual admission checks against a live gateway: mutating tools
#             absent from tools/list AND refused on tools/call, allowlisted
#             tools admitted, calls audited.
#
# The tools/call check is the one that matters. Hiding a tool from the listing
# is cosmetic, because a client that knows the name can call it regardless.
#
#   bash tests/security/run-rapid7-tests.sh [--json <path>]
#
# Static checks always run. Runtime checks are skipped, not failed, when the
# gateway is down - that is what makes this runnable before the server is first
# enabled. Exit code is the number of failures.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

export XDG_CONFIG_HOME="$ROOT/runtime/toolhive/config"
export XDG_DATA_HOME="$ROOT/runtime/toolhive/data"
export XDG_STATE_HOME="$ROOT/runtime/toolhive/state"
THV="$ROOT/runtime/toolhive/bin/thv"

SERVER=gw-rapid7-insightidr
SOURCE="$ROOT/runtime/mcp/r7-insightidr/src/mcp_insightidr/tools"

JSON_OUT=""
[[ "${1:-}" == "--json" ]] && JSON_OUT="${2:?--json needs a path}"

FAILURES=0
TOTAL=0
ROWS=()

record() {
  local state="$1" name="$2" detail="$3"
  TOTAL=$((TOTAL + 1))
  local mark="pass"
  case "$state" in
    fail) mark="FAIL"; FAILURES=$((FAILURES + 1)) ;;
    skip) mark="skip" ;;
  esac
  printf '  %s  %-52s %s\n' "$mark" "$name" "$detail"
  ROWS+=("{\"check\":\"$name\",\"state\":\"$state\",\"detail\":\"${detail//\"/}\"}")
}

echo
echo "Rapid7 InsightIDR - tool admission"
echo

# --- STATIC: the allowlist must be a subset of the annotated read-only set ----

if [[ ! -d "$SOURCE" ]]; then
  record fail "source available for verification" "checkout missing at runtime/mcp/r7-insightidr"
else
  ANALYSIS="$(python3 - "$SOURCE" <<'PY'
import json, pathlib, re, sys, yaml

src = pathlib.Path(sys.argv[1])
readonly, mutating = set(), set()
for f in src.glob("*.py"):
    for m in re.finditer(r'@mcp\.tool\((.*?)\)\s*\n\s*(?:async\s+)?def\s+(\w+)', f.read_text(), re.S):
        (readonly if 'readOnlyHint": True' in m.group(1) else mutating).add(m.group(2))

cfg = yaml.safe_load(open("config/toolhive/servers.yaml"))
entry = next((s for s in cfg["servers"] if s["name"] == "rapid7-insightidr"), {})
allow = entry.get("tools") or []

print(json.dumps({
    "readonly": len(readonly),
    "mutating": len(mutating),
    "allowed": len(allow),
    # The failure condition: anything exposed that upstream does not mark
    # read-only. Empty is the only acceptable value.
    "violations": sorted(set(allow) - readonly),
    "unknown": sorted(t for t in allow if t not in readonly | mutating),
}))
PY
)"

  if [[ -z "$ANALYSIS" ]]; then
    record fail "source annotations parsed" "could not analyse upstream source"
  else
    ro=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['readonly'])" "$ANALYSIS")
    mu=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['mutating'])" "$ANALYSIS")
    al=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['allowed'])" "$ANALYSIS")
    vi=$(python3 -c "import json,sys; print(','.join(json.loads(sys.argv[1])['violations']))" "$ANALYSIS")
    un=$(python3 -c "import json,sys; print(','.join(json.loads(sys.argv[1])['unknown']))" "$ANALYSIS")

    record pass "upstream tool surface classified" "$ro read-only, $mu mutating or unannotated"

    if [[ -z "$vi" ]]; then
      record pass "allowlist is read-only by derivation" "$al exposed, all annotated readOnlyHint"
    else
      record fail "allowlist is read-only by derivation" "MUTATING TOOL EXPOSED: $vi"
    fi

    # A configured tool that exists in neither set means the name is wrong, or
    # upstream renamed it. Either way the allowlist no longer says what it means.
    if [[ -z "$un" ]]; then
      record pass "every allowlisted tool exists upstream" "no unknown names"
    else
      record fail "every allowlisted tool exists upstream" "not found in source: $un"
    fi
  fi
fi

# --- RUNTIME: admission, which only a live gateway can demonstrate -----------

if [[ ! -x "$THV" ]] || ! "$THV" list 2>/dev/null | grep -q "$SERVER.*running"; then
  record skip "runtime admission checks" "gateway not running - bash scripts/toolhive-up.sh"
  echo
  echo "  $((TOTAL - FAILURES)) of $TOTAL checks passed, $FAILURES failed (runtime checks skipped)"
  echo
  [[ -n "$JSON_OUT" ]] && {
    mkdir -p "$(dirname "$JSON_OUT")"
    { printf '{\n  "capturedAt": "%s",\n  "total": %d,\n  "failures": %d,\n  "checks": [\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TOTAL" "$FAILURES"
      for i in "${!ROWS[@]}"; do
        printf '    %s%s\n' "${ROWS[$i]}" "$([[ $i -lt $((${#ROWS[@]} - 1)) ]] && echo ,)"
      done
      printf '  ]\n}\n'; } > "$JSON_OUT"
  }
  exit "$FAILURES"
fi

LISTED="$("$THV" mcp list tools --server "$SERVER" 2>&1)"

# The mutating tools most likely to be admitted by a careless filter.
for tool in investigate_alerts generate_alert_report bulk_close_investigations \
            update_alert set_investigation_status delete_log; do
  if grep -qE "^\s*${tool}[[:space:]]" <<<"$LISTED"; then
    record fail "mutating tool hidden: $tool" "ADVERTISED - filter not applied"
  else
    record pass "mutating tool hidden: $tool" "absent from tools/list"
  fi
done

# The check that actually enforces anything.
for tool in investigate_alerts bulk_close_investigations delete_log; do
  OUT="$(timeout 60 "$THV" mcp call "$tool" --server "$SERVER" --args '{}' 2>&1)"
  if grep -qiE 'tool not found|not allowed|forbidden|unauthorized|unknown tool' <<<"$OUT"; then
    record pass "mutating tool refused on call: $tool" "gateway refused: tool not found"
  else
    record fail "mutating tool refused on call: $tool" "REACHED SERVER - admission not enforced"
  fi
done

# A read-only tool must still be admitted, or the integration is useless.
OUT="$(timeout 90 "$THV" mcp call list_investigations --server "$SERVER" --args '{}' 2>&1)"
if grep -qiE 'tool not found|not allowed' <<<"$OUT"; then
  record fail "allowlisted tool admitted: list_investigations" "REFUSED - over-filtering"
else
  record pass "allowlisted tool admitted: list_investigations" "reached the server, not refused"
fi

AUDIT_LOG="$XDG_DATA_HOME/toolhive/logs/$SERVER.log"
if [[ -f "$AUDIT_LOG" ]] && grep -q '"type":"mcp_tool_call"' "$AUDIT_LOG"; then
  N=$(grep -c '"type":"mcp_tool_call"' "$AUDIT_LOG")
  record pass "tool calls audited" "$N mcp_tool_call events"
else
  record fail "tool calls audited" "no mcp_tool_call events found"
fi

echo
echo "  $((TOTAL - FAILURES))/$TOTAL passed, $FAILURES failed"
echo

if [[ -n "$JSON_OUT" ]]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  {
    printf '{\n  "capturedAt": "%s",\n  "server": "%s",\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SERVER"
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
