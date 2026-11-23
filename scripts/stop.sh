#!/usr/bin/env bash
# Stop only the processes this POC started.
#
# The stack does not stay in one process group: agent-canvas spawns agent-server
# through uvx, which re-parents into a group of its own, and each ACP subprocess
# hangs off agent-server. Killing the canvas process group alone leaves
# agent-server and the `agent acp` subprocesses running.
#
# So targets are identified three ways, each uniquely attributable to this POC:
#   1. recursive descendants of the pid recorded in runtime/agent-canvas.pid
#   2. whatever is listening on this POC's ports
#   3. any process whose command line contains this POC's absolute path
#      (the ACP shim is launched by absolute path, so this catches strays)
#
# Unrelated Cursor, Node, Python, and Docker processes are never touched - in
# particular the developer's Django server on port 8000.

CANVAS_ONLY=0
[[ "${1:-}" == "--canvas-only" ]] && CANVAS_ONLY=1

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
set +e

# The gateway goes down deliberately, and first.
#
# Skipped with --canvas-only so ToolHive/DBHub keep running during a Canvas
# restart (e.g. switching to --public with a new LOCAL_BACKEND_API_KEY).
if [[ "$CANVAS_ONLY" -eq 0 ]] && [[ -x "$POC_ROOT/runtime/toolhive/bin/thv" ]]; then
  XDG_CONFIG_HOME="$POC_ROOT/runtime/toolhive/config" \
  XDG_DATA_HOME="$POC_ROOT/runtime/toolhive/data" \
  XDG_STATE_HOME="$POC_ROOT/runtime/toolhive/state" \
    bash "$POC_ROOT/scripts/toolhive-up.sh" --stop >/dev/null 2>&1
fi

declare -A TARGETS=()

add_target() {
  local pid="$1"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$pid" -gt 1 ]] || return 0
  # Never signal this script, its shell, or any of our own ancestors.
  local p="$$"
  while [[ -n "$p" && "$p" -gt 1 ]]; do
    [[ "$pid" == "$p" ]] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  TARGETS["$pid"]=1
}

collect_descendants() {
  local pid="$1"
  add_target "$pid"
  local child
  for child in $(ps -o pid= --ppid "$pid" 2>/dev/null); do
    collect_descendants "$child"
  done
}

# 1. process tree from the recorded pid
if pid="$(canvas_pid)"; then
  dim "recorded canvas pid: $pid"
  collect_descendants "$pid"
else
  warn "no live pid recorded in runtime/agent-canvas.pid"
fi

# 2. listeners on this POC's ports (ingress, agent-server, automation, frontend)
for port in "$POC_PORT" "$AGENT_SERVER_PORT" 18001 "$CANVAS_FRONTEND_PORT"; do
  while read -r listener; do
    add_target "$listener"
  done < <(ss -tlnpH "sport = :${port}" 2>/dev/null |
             grep -oP 'pid=\K[0-9]+' | sort -u)
done

# 3. anything launched from this workspace (catches orphaned ACP subprocesses)
while read -r stray; do
  if [[ "$CANVAS_ONLY" -eq 1 ]]; then
    # start-local-shared restarts Canvas while ToolHive/DBHub stay up; thv workers
    # live under this POC path and must not be SIGKILL'd with the canvas tree.
    ps -o args= -p "$stray" 2>/dev/null | grep -q 'runtime/toolhive/bin/thv' && continue
    # Same for the prod Django worker: start-local-shared starts it before this
    # canvas-only restart, so sweeping it here leaves every job unprocessed.
    ps -o args= -p "$stray" 2>/dev/null | grep -q 'scripts/django-prod-host-worker.sh' && continue
  fi
  add_target "$stray"
done < <(pgrep -f "$POC_ROOT" 2>/dev/null)

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  warn "nothing to stop"
  rm -f "$PID_FILE" "${POC_ROOT}/runtime/.smoke-ok"
  exit 0
fi

heading "Stopping ${#TARGETS[@]} process(es)"
for pid in "${!TARGETS[@]}"; do
  printf '  %-8s %s\n' "$pid" "$(dim "$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-90)")"
done

for pid in "${!TARGETS[@]}"; do
  kill -TERM "$pid" 2>/dev/null
done

for _ in $(seq 1 20); do
  remaining=0
  for pid in "${!TARGETS[@]}"; do
    kill -0 "$pid" 2>/dev/null && remaining=$((remaining + 1))
  done
  [[ $remaining -eq 0 ]] && break
  sleep 0.5
done

survivors=()
for pid in "${!TARGETS[@]}"; do
  kill -0 "$pid" 2>/dev/null && survivors+=("$pid")
done

if [[ ${#survivors[@]} -gt 0 ]]; then
  warn "${#survivors[@]} did not exit on SIGTERM, sending SIGKILL"
  for pid in "${survivors[@]}"; do
    kill -KILL "$pid" 2>/dev/null
  done
  sleep 1
fi

still=0
for pid in "${!TARGETS[@]}"; do
  kill -0 "$pid" 2>/dev/null || continue
  # Zombies answer kill -0 until the parent reaps them; they hold no ports and
  # are not stoppable — treating them as survivors blocked restart after Ctrl+Z.
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
  [[ "$stat" == Z* ]] && continue
  bad "pid $pid still running"
  still=1
done

rm -f "$PID_FILE" "${POC_ROOT}/runtime/.smoke-ok"
if [[ "$CANVAS_ONLY" -eq 0 ]]; then
  rm -f "${POC_ROOT}/runtime/.prod-django-shell-enabled"
  rm -f "${POC_ROOT}/runtime/.beta-django-shell-enabled"
  if [[ -f "${POC_ROOT}/runtime/django-prod-worker.pid" ]]; then
    kill "$(cat "${POC_ROOT}/runtime/django-prod-worker.pid")" 2>/dev/null || true
    rm -f "${POC_ROOT}/runtime/django-prod-worker.pid"
  fi
  pkill -f "scripts/django-prod-host-worker.sh" 2>/dev/null || true
fi

echo
if [[ $still -eq 0 ]]; then
  ok "POC stopped"
else
  bad "some processes survived - inspect manually"
  exit 1
fi

if ss -tln 2>/dev/null | grep -q ":${POC_PORT}\b"; then
  warn "port ${POC_PORT} still bound by something outside this POC"
fi
if ss -tln 2>/dev/null | grep -q ":${CANVAS_FRONTEND_PORT}\b"; then
  warn "port ${CANVAS_FRONTEND_PORT} (canvas frontend) still bound - a new agent-canvas will fail until it is free"
fi

# Sanity check: the developer's Django server must be untouched.
if ss -tln 2>/dev/null | grep -q ":8000\b"; then
  dim "port 8000 still bound (unrelated Django server) - correctly left alone"
fi
