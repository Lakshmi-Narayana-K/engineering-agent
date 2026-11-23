#!/usr/bin/env bash
# Local shared testing: your machine, your VPN, prod + beta read-only DB (env_prod / env_beta).
# Teammates open http://<your-lan-ip>:8100 with the printed API key.
#
#   bash scripts/start-local-shared.sh
#
# Prerequisites: VPN on, Docker, ToolHive installed, repos bootstrapped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_common.sh"

ENV_PROD="${ENV_PROD:-$ROOT/repos/nkb_backend/env_prod.sh}"
ENV_BETA="${ENV_BETA:-$ROOT/repos/nkb_backend/env_beta.sh}"
AWS_SRC_PROFILE="${AWS_SRC_PROFILE:-default}"
THV="$ROOT/runtime/toolhive/bin/thv"
export XDG_CONFIG_HOME="$ROOT/runtime/toolhive/config"
export XDG_DATA_HOME="$ROOT/runtime/toolhive/data"
export XDG_STATE_HOME="$ROOT/runtime/toolhive/state"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"

heading "Local shared host setup"

[[ -f "$ENV_PROD" ]] || { bad "missing $ENV_PROD (VPN prod env)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_PROD"

: "${RDS_HOSTNAME:?RDS_HOSTNAME not set in env_prod}"
: "${RDS_USERNAME:?RDS_USERNAME not set in env_prod}"
: "${RDS_PASSWORD:?RDS_PASSWORD not set in env_prod}"
: "${RDS_DB_NAME:?RDS_DB_NAME not set in env_prod}"
RDS_PORT="${RDS_PORT:-3306}"

# Read-only Django shell on host (Poetry venv + env_prod / env_beta), queued from sandbox.
mkdir -p "$ROOT/runtime/django-prod-shell" "$ROOT/runtime/django-jobs" "$ROOT/runtime/logs"
chmod +x "$ROOT/runtime/django-prod-shell/"*.sh 2>/dev/null || true
chmod +x "$ROOT/scripts/django-prod-host-worker.sh" 2>/dev/null || true
chmod 1777 "$ROOT/runtime/django-jobs"

printf '%s\n' "$(readlink -f "$ENV_PROD")" >"$ROOT/runtime/prod-django-env.path"
chmod 600 "$ROOT/runtime/prod-django-env.path"
: >"$ROOT/runtime/.prod-django-shell-enabled"
ok "prod DB shell   $(dim "$(readlink -f "$ENV_PROD")")"

if [[ -f "$ENV_BETA" ]]; then
  (
    set -a
    # shellcheck disable=SC1090
    source "$ENV_BETA"
    set +a
    : "${RDS_HOSTNAME:?RDS_HOSTNAME not set in env_beta}"
    : "${RDS_USERNAME:?RDS_USERNAME not set in env_beta}"
    : "${RDS_PASSWORD:?RDS_PASSWORD not set in env_beta}"
    : "${RDS_DB_NAME:?RDS_DB_NAME not set in env_beta}"
  )
  printf '%s\n' "$(readlink -f "$ENV_BETA")" >"$ROOT/runtime/beta-django-env.path"
  chmod 600 "$ROOT/runtime/beta-django-env.path"
  : >"$ROOT/runtime/.beta-django-shell-enabled"
  ok "beta DB shell   $(dim "$(readlink -f "$ENV_BETA")")"
else
  rm -f "$ROOT/runtime/beta-django-env.path" "$ROOT/runtime/.beta-django-shell-enabled"
  warn "beta DB disabled  $(dim "missing $ENV_BETA")"
fi

if [[ -f "$ROOT/runtime/django-prod-worker.pid" ]]; then
  old_pid="$(cat "$ROOT/runtime/django-prod-worker.pid" 2>/dev/null || true)"
  [[ -n "$old_pid" ]] && kill "$old_pid" 2>/dev/null || true
  rm -f "$ROOT/runtime/django-prod-worker.pid"
fi
pkill -f "$ROOT/scripts/django-prod-host-worker.sh" 2>/dev/null || true
pkill -f "scripts/django-prod-host-worker.sh" 2>/dev/null || true
rm -f "$ROOT"/runtime/django-jobs/*.processing
nohup bash "$ROOT/scripts/django-prod-host-worker.sh" \
  >>"$ROOT/runtime/logs/django-prod-worker.log" 2>&1 &
echo $! >"$ROOT/runtime/django-prod-worker.pid"
sleep 1
if kill -0 "$(cat "$ROOT/runtime/django-prod-worker.pid")" 2>/dev/null; then
  ok "django-prod-host-worker started  $(dim "pid $(cat "$ROOT/runtime/django-prod-worker.pid")")"
else
  bad "django-prod-host-worker failed to start - see runtime/logs/django-prod-worker.log"
  exit 1
fi
if bash "$ROOT/scripts/django-prod-ping.sh" prod >/dev/null 2>&1; then
  ok "django-prod ping   $(dim "host ORM prod OK")"
else
  warn "django-prod ping failed - VPN/env_prod/venv? see runtime/logs/django-prod-worker.log"
fi
if [[ -f "$ROOT/runtime/.beta-django-shell-enabled" ]]; then
  if bash "$ROOT/scripts/django-prod-ping.sh" beta >/dev/null 2>&1; then
    ok "django-beta ping   $(dim "host ORM beta OK")"
  else
    warn "django-beta ping failed - VPN/env_beta/venv? see runtime/logs/django-prod-worker.log"
  fi
fi

case "$RDS_HOSTNAME" in
  *cluster-ro-*) ok "reader endpoint  $(dim "$RDS_HOSTNAME")" ;;
  *) warn "RDS_HOSTNAME does not look like a reader (cluster-ro-). Continuing anyway." ;;
esac

heading "Stage AWS creds for ToolHive (profile nkb-agent-alpha)"
mkdir -p "$ROOT/runtime/aws"
python3 - "$AWS_SRC_PROFILE" "$ROOT/runtime/aws/credentials" <<'PY'
import configparser, json, pathlib, subprocess, sys

profile, out = sys.argv[1], pathlib.Path(sys.argv[2])
raw = subprocess.check_output(
    ["aws", "configure", "export-credentials", "--profile", profile],
    text=True,
)
data = json.loads(raw)
cfg = configparser.ConfigParser()
section = {
    "aws_access_key_id": data["AccessKeyId"],
    "aws_secret_access_key": data["SecretAccessKey"],
}
token = data.get("SessionToken") or data.get("session_token")
if token:
    section["aws_session_token"] = token
cfg["nkb-agent-alpha"] = section
out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w") as fh:
    cfg.write(fh)
out.chmod(0o600)
PY
ok "runtime/aws/credentials  (from AWS profile $AWS_SRC_PROFILE)"

heading "Write DBHub config (password stays in env, not in file)"
cat >"$ROOT/runtime/dbhub.toml" <<EOF
[[sources]]
id = "prod"
type = "mysql"
host = "${RDS_HOSTNAME}"
port = ${RDS_PORT}
database = "${RDS_DB_NAME}"
user = "${RDS_USERNAME}"
aws_iam_auth = false
sslmode = "require"
connection_timeout = 10

[[tools]]
name = "execute_sql"
source = "prod"
readonly = true
max_rows = 1000
EOF
# The dbhub image runs as a non-root user; 600 makes it crash-loop on EACCES.
# No secret lives in this file (the password is injected via ToolHive).
chmod 644 "$ROOT/runtime/dbhub.toml"

mkdir -p "$ROOT/runtime/toolhive"
cat >"$ROOT/runtime/toolhive/db-permissions.local.json" <<EOF
{
  "read": [],
  "network": {
    "outbound": {
      "insecure_allow_all": false,
      "allow_host": ["${RDS_HOSTNAME}"],
      "allow_port": [3306]
    }
  }
}
EOF

export TOOLHIVE_SECRET_DB_PASSWORD="$RDS_PASSWORD"

heading "Start MCP gateway"
[[ -x "$THV" ]] || { bad "run bash scripts/toolhive-install.sh first"; exit 1; }
bash "$ROOT/scripts/toolhive-up.sh"

# Off by default: bytebase/dbhub:latest (2026-10-02) no longer reads the password
# from DB_PASSWORD and crash-loops. django-prod-shell covers ORM and raw SQL.
export NKB_ENABLE_DBHUB="${NKB_ENABLE_DBHUB:-0}"
"$THV" stop gw-dbhub >/dev/null 2>&1 || true
"$THV" rm gw-dbhub >/dev/null 2>&1 || true

if [[ "$NKB_ENABLE_DBHUB" == "1" ]]; then
  heading "Start DBHub (host network so VPN routes work)"
  "$THV" secret provider environment >/dev/null 2>&1 || true

  DBHUB_TOML="$(readlink -f "$ROOT/runtime/dbhub.toml")"
  PERMS="$(readlink -f "$ROOT/runtime/toolhive/db-permissions.local.json")"

  if ! "$THV" run --name gw-dbhub --enable-audit --proxy-port 19108 --transport stdio \
    --network host \
    --permission-profile "$PERMS" \
    --secret "DB_PASSWORD,target=DB_PASSWORD" \
    --volume "${DBHUB_TOML}:/dbhub.toml:ro" \
    --tools execute_sql --tools list_resources \
    bytebase/dbhub -- --config=/dbhub.toml >/dev/null 2>&1; then
    bad "DBHub failed - see runtime/toolhive/data/toolhive/logs/gw-dbhub.log"
    exit 1
  fi

  for _ in $(seq 1 24); do
    "$THV" list 2>/dev/null | grep -q 'gw-dbhub.*running' && break
    sleep 5
  done
  "$THV" list 2>/dev/null | grep -q 'gw-dbhub.*running' || {
    bad "DBHub not ready - VPN on? Can you mysql to the reader from this host?"
    exit 1
  }
  ok "DBHub running on :19108"
else
  dim "  DBHub disabled (NKB_ENABLE_DBHUB=1 to opt in); prod SQL goes through django-prod-shell"
fi

heading "Sandbox MCP config"
mkdir -p "$ROOT/workspace/agent-state"
python3 - "$ROOT/workspace/agent-state/mcp.json" <<'PYGEN'
import json, os, sys, yaml
out = sys.argv[1]
cfg = yaml.safe_load(open("config/toolhive/servers.yaml"))
servers = {
    s["name"]: {"url": f"http://host.docker.internal:{s['proxy_port']}/mcp"}
    for s in cfg.get("servers", [])
    if s.get("enabled") and s.get("proxy_port")
}
if os.environ.get("NKB_ENABLE_DBHUB") == "1":
    servers["dbhub"] = {"url": "http://host.docker.internal:19108/mcp"}
json.dump({"mcpServers": servers}, open(out, "w"), indent=2)
print("  " + ", ".join(sorted(servers)))
PYGEN

heading "Approve sandbox MCP"
approve_sandbox_mcp_servers

export LOCAL_BACKEND_API_KEY="${LOCAL_BACKEND_API_KEY:-nkb-shared-local}"
export NKB_CANVAS_PUBLIC=1
export NKB_POC_PORT="${NKB_POC_PORT:-8100}"
# Default active profile: nkb-investigator-agent (override with ask for read-only).
# Both profiles are published; users can switch in Canvas (new chat after switch).
export NKB_ACP_SESSION_MODE="${NKB_ACP_SESSION_MODE:-agent}"

heading "Restart Canvas (--public needs matching API key)"
bash "$ROOT/scripts/stop.sh" --canvas-only >/dev/null 2>&1 || true

heading "Start full agent stack"
bash "$ROOT/scripts/start.sh" --no-smoke

heading "Refresh sandbox MCP + approvals (after Canvas start)"
python3 - "$ROOT/workspace/agent-state/mcp.json" <<'PYGEN'
import json, os, sys, yaml
out = sys.argv[1]
cfg = yaml.safe_load(open("config/toolhive/servers.yaml"))
servers = {
    s["name"]: {"url": f"http://host.docker.internal:{s['proxy_port']}/mcp"}
    for s in cfg.get("servers", [])
    if s.get("enabled") and s.get("proxy_port")
}
if os.environ.get("NKB_ENABLE_DBHUB") == "1":
    servers["dbhub"] = {"url": "http://host.docker.internal:19108/mcp"}
json.dump({"mcpServers": servers}, open(out, "w"), indent=2)
PYGEN
approve_sandbox_mcp_servers

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
printf '\n'
ok "Share with teammates (keep VPN on on THIS machine):"
dim "  URL:     http://${LAN_IP:-<your-lan-ip>}:${NKB_POC_PORT}"
dim "  API key: $LOCAL_BACKEND_API_KEY"
dim "  Local:   http://localhost:${NKB_POC_PORT}"
dim "  Prod DB: django-prod-shell · Beta DB: django-beta-shell (read-only; VPN on this host)"
printf '\n'
dim "  Stop: bash scripts/stop.sh && bash scripts/toolhive-up.sh --stop"
printf '\n'
