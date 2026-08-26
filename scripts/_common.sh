#!/usr/bin/env bash
# Shared configuration and helpers for the POC scripts.
# Sourced, never executed directly.

set -euo pipefail

POC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export POC_ROOT

# Upstream default is 8000, which is occupied on this host by a developer's
# Django runserver. Override with NKB_POC_PORT if 8100 is also taken.
POC_PORT="${NKB_POC_PORT:-8100}"
POC_URL="http://localhost:${POC_PORT}"
AGENT_SERVER_PORT="${NKB_AGENT_SERVER_PORT:-18000}"
API_KEY="${LOCAL_BACKEND_API_KEY:-nkb-poc-local-key}"

PID_FILE="${POC_ROOT}/runtime/agent-canvas.pid"
LOG_DIR="${POC_ROOT}/runtime/logs"
CANVAS_LOG="${LOG_DIR}/agent-canvas.log"
BASELINE_DIR="${POC_ROOT}/runtime/cursor/baseline"
# Entry point of the ACP proxy chain:
#
#   Agent Server -> acp-policy-proxy -> cursor-compat-proxy -> agent-sandbox.sh
#                                                                  -> Cursor
#
# The policy proxy is first because it must see every message, and last to be
# influenced by anything downstream. Each link spawns the next, so only this
# path is configured anywhere.
#
# NKB_ACP_ENTRY overrides it, which is the rollback to the single-file shim
# that preceded the split. Kept working until the chain has run in daily use.
SHIM="${NKB_ACP_ENTRY:-${POC_ROOT}/runtime/acp-policy-proxy/index.mjs}"

REPOS=(nkb_backend nkb_assessment_backend nkb_learning_backend)

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_BAD=''; C_WARN=''; C_DIM=''; C_OFF=''
fi

ok()   { printf '%s✓%s %s\n' "$C_OK" "$C_OFF" "$*"; }
bad()  { printf '%s✗%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

heading() { printf '\n%s\n' "$*"; }

# Resolve repos/<name> to its real checkout path.
repo_path() {
  local link="${POC_ROOT}/repos/$1"
  [[ -e "$link" ]] || return 1
  readlink -f "$link"
}

api() {
  local method="$1" path="$2"
  shift 2
  curl -fsS -X "$method" -H "X-Session-API-Key: ${API_KEY}" "$@" "${POC_URL}${path}"
}

canvas_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

server_healthy() {
  curl -fsS -o /dev/null --max-time 3 "${POC_URL}/health" 2>/dev/null
}
