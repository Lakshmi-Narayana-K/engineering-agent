#!/usr/bin/env bash
#
# Filesystem and environment isolation, measured where it matters.
#
# This suite used to run on the host and describe the developer's machine, which
# says nothing about what the agent can reach. It now executes the checks inside
# the sandbox, through the same scripts/agent-sandbox.sh the Agent Server uses
# as its ACP command, so the configuration under test is the configuration that
# runs.
#
# The check script is piped in over stdin rather than mounted, so testing does
# not add a mount that a real session would not have.
#
#   bash tests/security/run-isolation-tests.sh [--json <path>] [--host]
#
# --host reproduces the old host-side view, kept only to show the contrast
# between "no boundary" and "boundary". Exit code is the number of open gaps.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

JSON_OUT=""
MODE=sandbox
while (($#)); do
  case "$1" in
    --json) JSON_OUT="${2:?--json needs a path}"; shift 2 ;;
    --host) MODE=host; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

GAPS=0
TOTAL=0
ROWS=()

emit() {
  local state="$1" name="$2" detail="$3"
  TOTAL=$((TOTAL + 1))
  local mark="pass"
  if [[ "$state" != "closed" ]]; then mark="GAP "; GAPS=$((GAPS + 1)); fi
  printf '  %s  %-40s %s\n' "$mark" "$name" "$detail"
  ROWS+=("{\"check\":\"$name\",\"state\":\"$state\",\"detail\":\"${detail//\"/}\"}")
}

echo

if [[ "$MODE" == host ]]; then
  echo "Isolation on the HOST - no boundary, shown for contrast"
  echo
  for repo in nkb_backend nkb_assessment_backend nkb_learning_backend; do
    if [[ -w "repos/$repo" ]]; then
      emit open "$repo read-only" "writable - symlink to a working copy"
    else
      emit closed "$repo read-only" "not writable"
    fi
  done
  [[ -e "$HOME/.aws"    ]] && emit open "host AWS config absent"    "readable at \$HOME/.aws"    || emit closed "host AWS config absent" "not present"
  [[ -e "$HOME/.cursor" ]] && emit open "host Cursor config absent" "readable at \$HOME/.cursor" || emit closed "host Cursor config absent" "not present"
  command -v aws >/dev/null 2>&1 && emit open "aws cli absent" "on PATH" || emit closed "aws cli absent" "not installed"
else
  if [[ ! -d workspace/repos ]]; then
    echo "  no clean workspace - run scripts/export-clean-source.sh first" >&2
    exit 1
  fi
  if ! docker image inspect "${NKB_AGENT_IMAGE:-nkb-agent-runtime:2026.08.11-e8db854}" >/dev/null 2>&1; then
    echo "  sandbox image missing - build docker/agent-runtime/Dockerfile first" >&2
    exit 1
  fi

  echo "Isolation INSIDE the sandbox - the boundary the agent actually faces"
  echo

  OUTPUT="$(bash scripts/agent-sandbox.sh --exec bash -s \
              < tests/security/in-sandbox-checks.sh 2>&1)" || true

  if ! grep -q '^RESULT ' <<<"$OUTPUT"; then
    echo "  no results from the sandbox:" >&2
    sed 's/^/    /' <<<"$OUTPUT" >&2
    exit 1
  fi

  while IFS= read -r line; do
    [[ "$line" == RESULT* ]] || continue
    rest="${line#RESULT }"
    state="${rest%% *}"; rest="${rest#* }"
    name="${rest%% :: *}"
    detail="${rest#* :: }"
    emit "$state" "$name" "$detail"
  done <<<"$OUTPUT"
fi

echo
echo "  $((TOTAL - GAPS))/$TOTAL closed, $GAPS open"
echo

if [[ -n "$JSON_OUT" ]]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  {
    printf '{\n  "capturedAt": "%s",\n  "mode": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE"
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
