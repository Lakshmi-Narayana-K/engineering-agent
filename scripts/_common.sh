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
# Agent Canvas static frontend (dev-safe assertPortsFree). Not the ingress port
# (POC_PORT). Orphans easily: the static-server child does not mention this POC
# path in its argv, so stop.sh's pgrep sweep misses it unless we bind this port.
CANVAS_FRONTEND_PORT="${NKB_CANVAS_FRONTEND_PORT:-${PORT:-3001}}"
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

# The repository set, and where each one really lives. This is the single
# source for both, because it used to be three: an array here, a source map in
# bootstrap.sh, and a second array in export-clean-source.sh. Adding a repo to
# two of the three silently produced a workspace whose symlinks and whose
# exported source disagreed about what the agent could see.
REPOS=(
  nkb_backend
  nkb_assessment_backend
  nkb_learning_backend
  ccbp-ide-drops-frontend
  ccbp-ide-drops-infra
  kossip-web
)

declare -A REPO_SOURCES=(
  [nkb_backend]=/home/nxtwave/Desktop/CodeBase-HUB/nkb_backend
  [nkb_assessment_backend]=/home/nxtwave/Desktop/CodeBase-HUB/nkb_assessment_backend
  [nkb_learning_backend]=/home/nxtwave/Desktop/CodeBase-HUB/nkb_learning_backend
  [ccbp-ide-drops-frontend]=/home/nxtwave/Desktop/CodeBase-HUB/Drops/ccbp-ide-drops-frontend
  [ccbp-ide-drops-infra]=/home/nxtwave/Desktop/CodeBase-HUB/Drops/ccbp-ide-drops-infra
  [kossip-web]=/home/nxtwave/Desktop/CodeBase-HUB/kossip-web
)

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

# Cursor inside the sandbox reads workspace/agent-state/.cursor as HOME. Gateway
# MCP URLs live in workspace/agent-state/mcp.json (written by toolhive-up or
# start-local-shared). Each server must be on the CLI approved list there or
# tool calls never leave the agent.
approve_sandbox_mcp_servers() {
  local mcp="${POC_ROOT}/workspace/agent-state/mcp.json"
  [[ -f "$mcp" ]] || return 0
  local servers
  servers="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("mcpServers",{})))' "$mcp" 2>/dev/null || true)"
  [[ -n "$servers" ]] || return 0

  # Sandbox mounts workspace/agent-state at /home/agent/.cursor, so mcp.json
  # lives at agent-state/mcp.json. `agent mcp enable` expects HOME/.cursor/mcp.json,
  # so approve through a one-off staging HOME, then copy cli-config back.
  local sandbox_home="${POC_ROOT}/workspace/agent-state"
  local staging="${POC_ROOT}/runtime/sandbox-cursor-staging"
  mkdir -p "$sandbox_home" "$staging/.cursor"
  cp "$mcp" "$staging/.cursor/mcp.json"
  cp "${POC_ROOT}/.cursor/cli.json" "$staging/.cursor/cli.json" 2>/dev/null || true

  for server in $servers; do
    if HOME="$staging" agent mcp enable "$server" >/dev/null 2>&1; then
      ok "MCP approved (sandbox)  $(dim "$server")"
    else
      warn "could not approve sandbox MCP server: $server"
    fi
  done

  if [[ -f "$staging/.cursor/cli-config.json" ]]; then
    cp "$staging/.cursor/cli-config.json" "$sandbox_home/cli-config.json"
    mkdir -p "$sandbox_home/.cursor"
    cp "$staging/.cursor/cli-config.json" "$sandbox_home/.cursor/cli-config.json"
  fi
}
