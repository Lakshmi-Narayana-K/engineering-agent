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
[[ -f "$SHIM" ]] || { bad "ACP shim missing"; exit 1; }
ok "ACP shim present"

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
else
  bad "runtime/cursor/api-key is missing or empty"
  dim "  Without it HOME cannot be isolated, so the agent would fall back to"
  dim "  your personal ~/.cursor config and its MCP servers."
  exit 1
fi

heading "Sandbox:"
# Opt-in with NKB_SANDBOX=1, because the sandbox changes where Cursor runs and
# therefore what it can reach. Host mode remains the default until the governed
# MCP path is proven in daily use; both modes are kept working so there is a
# rollback that does not involve editing code.
#
# The variable is set on the agent-canvas launch below rather than exported here.
# Canvas spawns agent-server, which spawns the shim, and each inherits its
# parent's environment - so setting it at the top of that chain is what reaches
# the shim, which reads NKB_AGENT_COMMAND to decide whether to run Cursor in a
# container instead of on the host.
SANDBOX_ENV=()
if [[ "${NKB_SANDBOX:-}" == "1" ]]; then
  sandbox_ok=true

  if docker image inspect "${NKB_AGENT_IMAGE:-nkb-agent-runtime:2026.08.11-e8db854}" >/dev/null 2>&1; then
    ok "image built  $(dim "${NKB_AGENT_IMAGE:-nkb-agent-runtime:2026.08.11-e8db854}")"
  else
    bad "sandbox image missing"
    dim "  docker build -t nkb-agent-runtime:2026.08.11-e8db854 docker/agent-runtime"
    sandbox_ok=false
  fi

  if [[ -d "$POC_ROOT/workspace/repos" ]] && [[ -n "$(ls -A "$POC_ROOT/workspace/repos" 2>/dev/null)" ]]; then
    ok "clean source exported  $(dim "$(ls "$POC_ROOT/workspace/repos" | tr '\n' ' ')")"
  else
    bad "no clean source workspace"
    dim "  bash scripts/export-clean-source.sh"
    sandbox_ok=false
  fi

  # Without the gateway the sandbox has no MCP at all: AWS, and later Rapid7 and
  # the database, simply disappear. Better to say so than to hand the user an
  # agent that silently cannot look anything up.
  if [[ -f "$POC_ROOT/workspace/agent-state/mcp.json" ]] \
     && grep -q '"url"' "$POC_ROOT/workspace/agent-state/mcp.json" 2>/dev/null; then
    ok "MCP gateway configured  $(dim "$(python3 -c "
import json; print(', '.join(json.load(open('$POC_ROOT/workspace/agent-state/mcp.json'))['mcpServers']))" 2>/dev/null)")"
  else
    bad "no gateway config for the sandbox"
    dim "  bash scripts/toolhive-up.sh"
    sandbox_ok=false
  fi

  if [[ "$sandbox_ok" != true ]]; then
    bad "sandbox requested but prerequisites are missing"
    exit 1
  fi

  SANDBOX_ENV=(NKB_AGENT_COMMAND="$POC_ROOT/scripts/agent-sandbox.sh")
  ok "enabled  $(dim "Cursor runs in a container, product source mounted read-only")"
else
  dim "host mode  (NKB_SANDBOX=1 to run Cursor in the container instead)"
fi

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
  setsid nohup env "LOCAL_BACKEND_API_KEY=$API_KEY" "${SANDBOX_ENV[@]}" \
    agent-canvas --port "$POC_PORT" \
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
import json, sys
print(json.dumps({"agent_settings_diff": {
    "agent_kind": "acp",
    "acp_server": "custom",
    "acp_command": ["node", sys.argv[1], "acp"],
    "acp_args": [],
    "acp_session_mode": "ask",
    "acp_prompt_timeout": 900.0,
    "acp_startup_timeout": 120.0,
}}))
PY
)"

if api PATCH /api/settings -H "Content-Type: application/json" -d "$patch_body" >/dev/null; then
  kind="$(api GET /api/settings | python3 -c 'import json,sys; print(json.load(sys.stdin)["agent_settings"]["agent_kind"])')"
  if [[ "$kind" == "acp" ]]; then
    ok "registered  $(dim "agent_kind=acp, acp_server=custom, mode=ask")"
  else
    bad "settings applied but agent_kind is '$kind'"
    exit 1
  fi
else
  bad "failed to apply ACP settings"
  exit 1
fi

heading "Agent profile:"
# Settings alone are not enough for the browser UI. The composer is gated on the
# *active agent profile*, and the stock 'default' profile is agent_kind=openhands,
# which demands an LLM API key we deliberately do not set. Publishing an ACP
# profile and activating it is what unblocks typing in the UI.
#
# Note the profile schema differs from the settings schema: here acp_command is a
# single string, so the shim path (which contains a space) goes in acp_args.
profile_body="$(python3 - "$SHIM" <<'PY'
import json, sys
print(json.dumps({
    "schema_version": 2,
    "name": "nkb-investigator",
    "agent_kind": "acp",
    "acp_server": "custom",
    "acp_command": "node",
    "acp_args": [sys.argv[1], "acp"],
    "acp_model": None,
    "acp_session_mode": "ask",
    "acp_prompt_timeout": 900.0,
    "acp_startup_timeout": 120.0,
    "mcp_server_refs": None,
}))
PY
)"

if api POST /api/agent-profiles/nkb-investigator \
     -H "Content-Type: application/json" -d "$profile_body" >/dev/null; then
  profile_id="$(api GET /api/agent-profiles | python3 -c '
import json, sys
for p in json.load(sys.stdin)["profiles"]:
    if p["name"] == "nkb-investigator":
        print(p["id"]); break
')"
  if [[ -n "$profile_id" ]] && api POST "/api/agent-profiles/${profile_id}/activate" >/dev/null; then
    ok "activated  $(dim "nkb-investigator (agent_kind=acp)")"
  else
    bad "profile saved but could not be activated"
    exit 1
  fi
else
  bad "failed to publish the nkb-investigator agent profile"
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
