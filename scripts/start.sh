#!/usr/bin/env bash
# Start the complete local POC: validate repos and Cursor, launch the Agent Canvas
# stack (which starts Agent Server itself), register Cursor as the custom ACP
# provider, wait for health, and print the UI URL.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SKIP_SMOKE=0
[[ "${1:-}" == "--no-smoke" ]] && SKIP_SMOKE=1

printf '\nNKB Agent POC\n'

heading "Repos:"
for repo in "${REPOS[@]}"; do
  if path="$(repo_path "$repo")" && [[ -d "$path/.git" ]]; then
    ok "$repo  $(dim "$(git -C "$path" rev-parse --abbrev-ref HEAD) @ $(git -C "$path" rev-parse --short HEAD)")"
  else
    bad "$repo  (run ./scripts/bootstrap.sh)"
    exit 1
  fi
done

heading "Cursor:"
if agent acp --help >/dev/null 2>&1; then
  ok "ACP available  $(dim "$(agent --version 2>/dev/null)")"
else
  bad "ACP unavailable - upgrade Cursor CLI"
  exit 1
fi
[[ -f "$SHIM" ]] || { bad "ACP policy proxy missing"; exit 1; }
ok "ACP proxy chain present"

# Cursor reads config from ~/.cursor and `agent acp` has no flag to redirect it,
# so the shim overrides HOME to an in-repo directory. Two consequences handled
# here: the API key becomes mandatory (the developer's cached login is no longer
# reachable), and MCP servers need approving inside that isolated home. The
# approval cache is gitignored runtime state, so a fresh clone must re-approve --
# doing it on every start keeps the setup reproducible rather than manual.
CURSOR_HOME="${POC_ROOT}/runtime/cursor-home"
if [[ -s "${POC_ROOT}/runtime/cursor/api-key" ]]; then
  ok "API key present  $(dim "isolated HOME at runtime/cursor-home")"

  mkdir -p "${CURSOR_HOME}/.cursor"
  cp "${POC_ROOT}/.cursor/mcp.json" "${POC_ROOT}/.cursor/cli.json" \
     "${CURSOR_HOME}/.cursor/" 2>/dev/null || true
  mkdir -p "${POC_ROOT}/workspace/agent-state"
  cp "${POC_ROOT}/.cursor/cli.json" "${POC_ROOT}/workspace/agent-state/cli.json" 2>/dev/null || true
  chmod -R go-rwx "$CURSOR_HOME" 2>/dev/null || true

  declared="$(python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    print(" ".join(json.load(fh).get("mcpServers", {})))
' "${POC_ROOT}/.cursor/mcp.json" 2>/dev/null || true)"

  for server in $declared; do
    if HOME="$CURSOR_HOME" agent mcp enable "$server" >/dev/null 2>&1; then
      ok "MCP approved  $(dim "$server")"
    else
      bad "could not approve MCP server: $server"
    fi
  done

  approve_sandbox_mcp_servers
else
  bad "runtime/cursor/api-key is missing or empty"
  dim "  Without it HOME cannot be isolated, so the agent would fall back to"
  dim "  your personal ~/.cursor config and its MCP servers."
  exit 1
fi

heading "Sandbox:"
# The only mode. Host mode has been removed.
#
# It ran Cursor as the developer, where it could read any file the developer
# could read and spawned its own MCP servers from ~/.cursor/mcp.json with
# credentials sitting in the config. The only thing between it and the
# developer's ~/.aws was our own code remembering to redirect HOME - a
# protection we wrote, in the same process that relayed the protocol.
#
# The sandbox does not deny those paths, it does not have them, and the kernel
# is what enforces that. Once ToolHive carried AWS and Rapid7 into the
# container there was nothing host mode could still do that this cannot, so
# keeping it meant maintaining a weaker path for no remaining benefit - along
# with the ~124 lines of HOME redirection and credential juggling that existed
# solely to make it survivable.
#
# The variable is set on the agent-canvas launch below rather than exported here.
# Canvas spawns agent-server, which spawns the shim, and each inherits its
# parent's environment - so setting it at the top of that chain is what reaches
# the shim, which reads NKB_AGENT_COMMAND to decide whether to run Cursor in a
# container instead of on the host.
SANDBOX_ENV=()
if [[ "${NKB_SANDBOX:-1}" == "0" ]]; then
  bad "NKB_SANDBOX=0 requests host mode, which no longer exists"
  dim "  Cursor now always runs in the container. If you are working around a"
  dim "  sandbox problem, fix it or say so - do not run the agent unconfined."
  exit 1
fi

sandbox_ok=true

AGENT_IMAGE="${NKB_AGENT_IMAGE:-nkb-agent-runtime:2026.08.11-e8db854}"
if bash "$POC_ROOT/scripts/ensure-sandbox-image.sh"; then
  ok "image built  $(dim "$AGENT_IMAGE")"
else
  bad "sandbox image unavailable"
  dim "  docker build -t $AGENT_IMAGE docker/agent-runtime"
  sandbox_ok=false
fi

if [[ -d "$POC_ROOT/workspace/repos" ]] && [[ -n "$(ls -A "$POC_ROOT/workspace/repos" 2>/dev/null)" ]]; then
  ok "clean source exported  $(dim "$(ls "$POC_ROOT/workspace/repos" | tr '\n' ' ')")"
else
  bad "no clean source workspace"
  dim "  bash scripts/export-clean-source.sh"
  sandbox_ok=false
fi

# The gateway is a dependency of this mode, so start it rather than asking the
# user to remember. Without it the sandbox has no MCP at all and AWS, Rapid7
# and later the database simply vanish.
#
# Checking that something ANSWERS, not that a config file exists. That
# distinction is not academic: stop.sh sweeps by port and by process
# descendants, which takes the gateway down with the stack, while
# workspace/agent-state/mcp.json survives. The file-only check therefore
# reported a configured gateway when nothing was listening, and the agent
# would have started with every external capability silently missing - the
# smoke test would still pass, because it does not use MCP.
export XDG_CONFIG_HOME="$POC_ROOT/runtime/toolhive/config"
export XDG_DATA_HOME="$POC_ROOT/runtime/toolhive/data"
export XDG_STATE_HOME="$POC_ROOT/runtime/toolhive/state"

if [[ -x "$POC_ROOT/runtime/toolhive/bin/thv" ]] \
   && "$POC_ROOT/runtime/toolhive/bin/thv" list 2>/dev/null | grep -q running; then
  ok "MCP gateway running  $(dim "$("$POC_ROOT/runtime/toolhive/bin/thv" list 2>/dev/null | grep -c running) server(s)")"
elif [[ -x "$POC_ROOT/runtime/toolhive/bin/thv" ]]; then
  dim "  starting MCP gateway..."
  if bash "$POC_ROOT/scripts/toolhive-up.sh" >/dev/null 2>&1 \
     && "$POC_ROOT/runtime/toolhive/bin/thv" list 2>/dev/null | grep -q running; then
    ok "MCP gateway started  $(dim "$("$POC_ROOT/runtime/toolhive/bin/thv" list 2>/dev/null | grep -c running) server(s)")"
  else
    bad "gateway failed to start"
    dim "  bash scripts/toolhive-up.sh   (to see why)"
    sandbox_ok=false
  fi
else
  bad "ToolHive is not installed"
  dim "  bash scripts/toolhive-install.sh"
  sandbox_ok=false
fi

# There is nothing to fall back to, and that is the point. When the sandbox
# cannot start, the answer is to fix it rather than to run the agent unconfined
# against production credentials.
if [[ "$sandbox_ok" != true ]]; then
  bad "cannot start the sandbox - fix the items above"
  exit 1
fi

# openhands-agent-server 1.42.1 passes Query(..., lte=100) in bash_router.py,
# which FastAPI >=0.150 rejects with TypeError. UV_CONSTRAINT splits on spaces,
# so the file must live at a space-free path outside "Agentic Workflows".
UV_CONSTRAINT_FILE="/tmp/nkb-agent-uv-constraints.txt"
printf 'fastapi<0.150\n' > "$UV_CONSTRAINT_FILE"
SANDBOX_ENV=(
  NKB_AGENT_COMMAND="$POC_ROOT/scripts/agent-sandbox.sh"
  UV_CONSTRAINT="$UV_CONSTRAINT_FILE"
)
ok "enabled  $(dim "Cursor runs in a container, product source mounted read-only")"

heading "Agent Server:"
mkdir -p "$LOG_DIR"

if pid="$(canvas_pid)"; then
  ok "already running  $(dim "pid $pid")"
else
  if ss -tln 2>/dev/null | grep -q ":${POC_PORT}\b"; then
    bad "port ${POC_PORT} is in use by another process"
    dim "  set NKB_POC_PORT to a free port and retry"
    exit 1
  fi
  # setsid puts the stack in its own process group, so stop.sh can terminate the
  # canvas, agent-server, and automation children together without guessing at
  # unrelated node/python processes on this machine.
  # `env` rather than an assignment prefix: bash decides which leading words are
  # assignments before expanding them, so a VAR=value word produced by array
  # expansion is treated as the command name instead of an assignment.
  CANVAS_ARGS=(--port "$POC_PORT")
  [[ "${NKB_CANVAS_PUBLIC:-}" == 1 ]] && CANVAS_ARGS+=(--public)
  setsid nohup env "LOCAL_BACKEND_API_KEY=$API_KEY" "${SANDBOX_ENV[@]}" \
    agent-canvas "${CANVAS_ARGS[@]}" \
    > "$CANVAS_LOG" 2>&1 &
  echo $! > "$PID_FILE"
  ok "starting  $(dim "pid $(cat "$PID_FILE"), log runtime/logs/agent-canvas.log")"
fi

printf '  waiting for health'
for _ in $(seq 1 90); do
  if server_healthy; then
    printf '\n'
    ok "running  $(dim "${POC_URL}/health")"
    break
  fi
  printf '.'
  sleep 2
done
if ! server_healthy; then
  printf '\n'
  bad "agent server did not become healthy - see runtime/logs/agent-canvas.log"
  exit 1
fi

heading "Agent Canvas:"
if curl -fsS -o /dev/null --max-time 5 "${POC_URL}/"; then
  ok "running"
else
  bad "ingress not responding on ${POC_URL}"
  exit 1
fi

heading "Cursor ACP provider:"
# acp_command is an argv array; the shim path contains a space, so build the
# JSON with python rather than string interpolation.
patch_body="$(python3 - "$SHIM" <<'PY'
import json, os, sys
print(json.dumps({"agent_settings_diff": {
    "agent_kind": "acp",
    "acp_server": "custom",
    "acp_command": ["node", sys.argv[1], "acp"],
    "acp_args": [],
    "acp_session_mode": os.environ.get("NKB_ACP_SESSION_MODE", "ask"),
    "acp_prompt_timeout": 900.0,
    "acp_startup_timeout": 120.0,
}}))
PY
)"

ACP_MODE="${NKB_ACP_SESSION_MODE:-ask}"
case "$ACP_MODE" in
  ask|agent) ;;
  *)
    bad "NKB_ACP_SESSION_MODE must be ask or agent (got: $ACP_MODE)"
    exit 1
    ;;
esac

if api PATCH /api/settings -H "Content-Type: application/json" -d "$patch_body" >/dev/null; then
  kind="$(api GET /api/settings | python3 -c 'import json,sys; print(json.load(sys.stdin)["agent_settings"]["agent_kind"])')"
  if [[ "$kind" == "acp" ]]; then
    ok "registered  $(dim "agent_kind=acp, acp_server=custom, default_mode=$ACP_MODE")"
  else
    bad "settings applied but agent_kind is '$kind'"
    exit 1
  fi
else
  bad "failed to apply ACP settings"
  exit 1
fi

heading "Agent profiles (ask + agent):"
# Settings alone are not enough for the browser UI. The composer is gated on the
# *active agent profile*, and the stock 'default' profile is agent_kind=openhands,
# which demands an LLM API key we deliberately do not set. Two profiles let users
# switch Cursor session mode in Canvas without restarting the host.
#
# Note the profile schema differs from the settings schema: here acp_command is a
# single string, so the shim path (which contains a space) goes in acp_args.
ACTIVE_PROFILE="nkb-investigator-${ACP_MODE}"
profile_publish_failed=0
for mode in ask agent; do
  name="nkb-investigator-${mode}"
  profile_body="$(python3 - "$SHIM" "$mode" <<'PY'
import json, sys
mode = sys.argv[2]
print(json.dumps({
    "schema_version": 2,
    "name": f"nkb-investigator-{mode}",
    "agent_kind": "acp",
    "acp_server": "custom",
    "acp_command": "node",
    "acp_args": [sys.argv[1], "acp"],
    "acp_model": None,
    "acp_session_mode": mode,
    "acp_prompt_timeout": 900.0,
    "acp_startup_timeout": 120.0,
    "mcp_server_refs": None,
}))
PY
)"
  if api POST "/api/agent-profiles/${name}" \
       -H "Content-Type: application/json" -d "$profile_body" >/dev/null; then
    ok "published  $(dim "$name (acp_session_mode=$mode)")"
  else
    bad "failed to publish $name"
    profile_publish_failed=1
  fi
done
if [[ $profile_publish_failed -ne 0 ]]; then
  exit 1
fi

profile_id="$(api GET /api/agent-profiles | python3 -c "
import json, sys
target = sys.argv[1]
for p in json.load(sys.stdin)[\"profiles\"]:
    if p[\"name\"] == target:
        print(p[\"id\"]); break
" "$ACTIVE_PROFILE")"
if [[ -n "$profile_id" ]] && api POST "/api/agent-profiles/${profile_id}/activate" >/dev/null; then
  ok "activated  $(dim "$ACTIVE_PROFILE (switch the other profile in Canvas anytime)")"
else
  bad "profiles saved but could not activate $ACTIVE_PROFILE"
  exit 1
fi

if [[ $SKIP_SMOKE -eq 0 ]]; then
  heading "Smoke test:"
  if python3 "${POC_ROOT}/runtime/smoke-test.py" >"${LOG_DIR}/smoke-test.log" 2>&1; then
    ok "Canvas -> Server -> ACP -> Cursor verified"
    date -Iseconds > "${POC_ROOT}/runtime/.smoke-ok"
  else
    bad "smoke test failed - see runtime/logs/smoke-test.log"
    tail -15 "${LOG_DIR}/smoke-test.log"
    exit 1
  fi
fi

printf '\nOpen:\n  %s\n\n' "$POC_URL"
dim "  stop with ./scripts/stop.sh   status with ./scripts/status.sh"
