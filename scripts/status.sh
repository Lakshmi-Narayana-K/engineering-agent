#!/usr/bin/env bash
# Report the state of every moving part of the POC.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
set +e   # a status report should never abort partway through

printf '\nNKB Agent POC - status\n'

heading "Runtime"
if pid="$(canvas_pid)"; then
  ok "Agent Canvas   running  $(dim "pid $pid, ${POC_URL}")"
else
  bad "Agent Canvas   not running"
fi

if server_healthy; then
  ok "Agent Server   healthy  $(dim "${POC_URL}/health -> 200")"
else
  bad "Agent Server   unreachable"
fi

if agent acp --help >/dev/null 2>&1; then
  ok "Cursor ACP     available  $(dim "$(agent --version 2>/dev/null)")"
else
  bad "Cursor ACP     unavailable"
fi

if [[ -f "$SHIM" ]]; then
  ok "ACP proxy     present"
else
  bad "ACP proxy     missing"
fi

heading "Engine configuration"
settings="$(api GET /api/settings 2>/dev/null)"
if [[ -n "$settings" ]]; then
  python3 - <<PY
import json
s = json.loads('''$settings''')["agent_settings"]
kind = s.get("agent_kind")
mark = "\u2713" if kind == "acp" else "\u2717"
print(f"{mark} agent_kind       {kind}")
print(f"  acp_server       {s.get('acp_server')}")
print(f"  acp_session_mode {s.get('acp_session_mode')}")
print(f"  acp_model        {s.get('acp_model') or '(cursor default)'}")
print(f"  acp_command      {' '.join(s.get('acp_command') or []) or '(unset)'}")
PY
  profiles="$(api GET /api/agent-profiles 2>/dev/null)"
  if [[ -n "$profiles" ]]; then
    python3 - <<PY
import json
data = json.loads('''$profiles''')
active = data.get("active_profile_id")
for p in data.get("profiles", []):
    mark = " (active)" if p.get("id") == active else ""
    mode = p.get("acp_session_mode") or "?"
    if p.get("name", "").startswith("nkb-investigator"):
        print(f"  profile          {p['name']}  mode={mode}{mark}")
PY
  fi
else
  bad "could not read /api/settings"
fi

heading "Shared read-only DB (start-local-shared)"
if [[ -f "${POC_ROOT}/runtime/.prod-django-shell-enabled" ]]; then
  ok "prod django     enabled"
else
  dim "  prod django shell not enabled"
fi
if [[ -f "${POC_ROOT}/runtime/.beta-django-shell-enabled" ]]; then
  ok "beta django     enabled"
else
  dim "  beta django shell not enabled"
fi
if [[ -f "${POC_ROOT}/runtime/.prod-django-shell-enabled" || -f "${POC_ROOT}/runtime/.beta-django-shell-enabled" ]]; then
  if [[ -f "${POC_ROOT}/runtime/django-prod-worker.pid" ]] \
     && kill -0 "$(cat "${POC_ROOT}/runtime/django-prod-worker.pid")" 2>/dev/null; then
    ok "host worker     running  $(dim "pid $(cat "${POC_ROOT}/runtime/django-prod-worker.pid")")"
    if bash "${POC_ROOT}/scripts/django-prod-ping.sh" prod >/dev/null 2>&1; then
      ok "host worker     prod ping OK"
    else
      bad "host worker     prod ping failed (VPN, env_prod, or venv?)"
    fi
    if [[ -f "${POC_ROOT}/runtime/.beta-django-shell-enabled" ]]; then
      if bash "${POC_ROOT}/scripts/django-prod-ping.sh" beta >/dev/null 2>&1; then
        ok "host worker     beta ping OK"
      else
        bad "host worker     beta ping failed (VPN, env_beta, or venv?)"
      fi
    fi
  else
    bad "host worker     not running"
  fi
fi

mcp="${POC_ROOT}/workspace/agent-state/mcp.json"
if [[ -f "$mcp" ]] && python3 -c 'import json,sys; exit(0 if "dbhub" in json.load(open(sys.argv[1])).get("mcpServers",{}) else 1)' "$mcp" 2>/dev/null; then
  THV="${POC_ROOT}/runtime/toolhive/bin/thv"
  if XDG_CONFIG_HOME="${POC_ROOT}/runtime/toolhive/config" \
     XDG_DATA_HOME="${POC_ROOT}/runtime/toolhive/data" \
     XDG_STATE_HOME="${POC_ROOT}/runtime/toolhive/state" \
     "$THV" list 2>/dev/null | grep -q 'gw-dbhub.*running'; then
    ok "DBHub gateway   running  $(dim ":19108/mcp")"
  else
    bad "DBHub gateway   in sandbox MCP but not running"
  fi
else
  dim "  DBHub disabled (NKB_ENABLE_DBHUB=1 to opt in)"
fi

heading "Repositories"
for repo in "${REPOS[@]}"; do
  if ! path="$(repo_path "$repo")"; then
    bad "$repo  link missing"
    continue
  fi
  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  head="$(git -C "$path" rev-parse --short HEAD 2>/dev/null)"
  now="$(git -C "$path" status --porcelain 2>/dev/null | wc -l)"
  base_file="${BASELINE_DIR}/${repo}.porcelain"
  base="$( [[ -f "$base_file" ]] && wc -l < "$base_file" || echo '?' )"

  printf '  %-24s %-38s %s\n' "$repo" "$branch @ $head" "$(dim "dirty ${now} (baseline ${base})")"
  printf '    %s\n' "$(dim "$path")"
done

heading "Generated context"
context_files=0
for f in "${POC_ROOT}"/context/system.yaml "${POC_ROOT}"/context/services/*.yaml; do
  [[ -f "$f" ]] && context_files=$((context_files + 1))
done
knowledge_files=$(find "${POC_ROOT}/knowledge" -name '*.md' 2>/dev/null | wc -l)

if [[ $context_files -ge 4 ]]; then
  ok "context        $context_files files  $(dim "system.yaml + services/")"
else
  warn "context        $context_files files (expected 4)"
fi
if [[ $knowledge_files -ge 8 ]]; then
  ok "knowledge      $knowledge_files documents"
else
  warn "knowledge      $knowledge_files documents (expected 8)"
fi

evals=$(find "${POC_ROOT}/evaluations/results" -type f 2>/dev/null | wc -l)
printf '  %s\n' "$(dim "evaluation results: ${evals} file(s)")"

heading "ACP smoke test"
if [[ -f "${POC_ROOT}/runtime/.smoke-ok" ]]; then
  ok "passed  $(dim "$(cat "${POC_ROOT}/runtime/.smoke-ok")")"
else
  warn "not run since last start  $(dim "run: python3 runtime/smoke-test.py")"
fi

echo
