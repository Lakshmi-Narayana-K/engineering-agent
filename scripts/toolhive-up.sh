#!/usr/bin/env bash
#
# Starts the MCP gateway.
#
# ToolHive's own state lives under runtime/toolhive/ rather than the developer's
# XDG directories, so the gateway is reproducible, inspectable and removable
# with the repository instead of leaving state behind in a home directory.
#
# Allowlists come from config/toolhive/servers.yaml, which is the single place
# tool admission is declared. Nothing here decides what is exposed.
#
#   bash scripts/toolhive-up.sh [--stop]
#
# First run pulls or builds images and can take a few minutes per server.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export XDG_CONFIG_HOME="$ROOT/runtime/toolhive/config"
export XDG_DATA_HOME="$ROOT/runtime/toolhive/data"
export XDG_STATE_HOME="$ROOT/runtime/toolhive/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

THV="$ROOT/runtime/toolhive/bin/thv"
CONFIG="$ROOT/config/toolhive/servers.yaml"

[[ -x "$THV" ]] || { echo "thv not found - run scripts/toolhive-install.sh" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG" >&2; exit 1; }

# Tab-separated so tool lists and endpoints survive intact.
mapfile -t ROWS < <(python3 - "$CONFIG" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
for s in cfg.get("servers", []):
    if not s.get("enabled"):
        continue
    tools = s.get("tools") or []
    if not tools:
        # Default-deny: a server with no allowlist would expose everything it has.
        print(f"SKIP {s['name']}: no tools allowlisted", file=sys.stderr)
        continue
    print("\t".join([
        s["name"],
        s.get("protocol") or s.get("registry") or s["name"],
        str(s.get("proxy_port", "")),
        ",".join(tools),
        s.get("transport", ""),
        s.get("endpoint", ""),
        s.get("region", ""),
        "yes" if s.get("credentials") else "no",
    ]))
PY
)

if [[ "${1:-}" == "--stop" ]]; then
  echo
  echo "Stopping gateway"
  for row in "${ROWS[@]}"; do
    name="gw-$(cut -f1 <<<"$row")"
    "$THV" stop "$name" >/dev/null 2>&1 && echo "  stopped $name" || true
    "$THV" rm "$name" >/dev/null 2>&1 || true
  done
  echo
  exit 0
fi

# ToolHive's environment secrets provider reads TOOLHIVE_SECRET_* variables.
# Chosen over a mounted credentials file because ToolHive drives its own Docker
# socket and ignores DOCKER_HOST: on a machine with both Docker Desktop and a
# system daemon, the daemon it picks may not be able to see the repository path,
# and a bind mount then silently yields an empty directory. Secret injection
# needs no shared filesystem.
"$THV" secret provider environment >/dev/null 2>&1 || true

stage_aws_secrets() {
  local creds="$ROOT/runtime/aws/credentials"
  [[ -f "$creds" ]] || return 1
  # Values are exported into this process only and never printed.
  eval "$(python3 - "$creds" <<'PY'
import configparser, shlex, sys
c = configparser.ConfigParser(); c.read(sys.argv[1])
p = "nkb-agent-alpha"
if c.has_section(p):
    for src, dst in (("aws_access_key_id", "AWS_ACCESS_KEY_ID"),
                     ("aws_secret_access_key", "AWS_SECRET_ACCESS_KEY"),
                     ("aws_session_token", "AWS_SESSION_TOKEN")):
        if c.has_option(p, src):
            print(f"export TOOLHIVE_SECRET_{dst}={shlex.quote(c.get(p, src))}")
PY
)"
  [[ -n "${TOOLHIVE_SECRET_AWS_ACCESS_KEY_ID:-}" ]]
}

echo
echo "Starting MCP gateway"
echo "  state    runtime/toolhive/"
echo "  bind     127.0.0.1 (sandbox reaches it via host.docker.internal)"
echo

# The sandbox's view of MCP, generated from the same config that started the
# gateways so the two cannot drift. Hand-writing this file was how the sandbox
# ended up pointing at a port nothing was listening on.
#
# Only URLs are written, never `command`/`args`/`env`. That distinction is the
# whole point of the gateway: a `command` entry would have Cursor spawn its own
# MCP server inside the sandbox, with no tool filtering and no audit trail. The
# in-sandbox isolation check asserts this file contains no such entry.
generate_sandbox_mcp() {
  local out="$ROOT/workspace/agent-state/mcp.json"
  mkdir -p "$(dirname "$out")"
  python3 - "$out" <<'PYGEN'
import json, sys, yaml
cfg = yaml.safe_load(open("config/toolhive/servers.yaml"))
servers = {
    s["name"]: {"url": f"http://host.docker.internal:{s['proxy_port']}/mcp"}
    for s in cfg.get("servers", [])
    if s.get("enabled") and s.get("proxy_port")
}
json.dump({"mcpServers": servers}, open(sys.argv[1], "w"), indent=2)
print(f"  sandbox mcp.json -> {', '.join(servers) or 'no servers'}")
PYGEN
}

for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r name package port tools transport endpoint region needs_creds <<<"$row"
  workload="gw-$name"

  if "$THV" list 2>/dev/null | grep -q "$workload.*running"; then
    echo "  already running  $workload"
    continue
  fi
  "$THV" rm "$workload" >/dev/null 2>&1 || true

  args=(run --name "$workload" --enable-audit)
  [[ -n "$port" ]] && args+=(--proxy-port "$port")

  # Explicit transport matters for stdio servers. Without it ToolHive assumes an
  # HTTP transport, the server reads EOF on stdin and exits cleanly, and the
  # workload sits in "starting" while restarting with exit code 0.
  [[ -n "$transport" ]] && args+=(--transport "$transport")

  if [[ "$needs_creds" == yes ]]; then
    if stage_aws_secrets; then
      args+=(--permission-profile config/toolhive/aws-permissions.json)
      for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
        # Indirect expansion with a default: AWS_SESSION_TOKEN is absent for
        # long-lived keys, and `set -u` would abort on a bare reference.
        varname="TOOLHIVE_SECRET_$v"
        [[ -n "${!varname:-}" ]] && args+=(--secret "$v,target=$v")
      done
      [[ -n "$region" ]] && args+=(--env "AWS_DEFAULT_REGION=$region" --env "AWS_REGION=$region")
    else
      echo "  skipping         $workload (no scoped credentials at runtime/aws/credentials)" >&2
      continue
    fi
  fi

  while IFS= read -r t; do args+=(--tools "$t"); done < <(tr ',' '\n' <<<"$tools")
  args+=("$package")
  [[ -n "$endpoint" ]] && args+=(-- "$endpoint" --metadata "AWS_REGION=${region:-us-east-1}")

  echo "  starting         $workload"
  "$THV" "${args[@]}" >/dev/null 2>&1 || {
    echo "    failed - see runtime/toolhive/data/toolhive/logs/$workload.log" >&2
    continue
  }

  for _ in $(seq 1 36); do
    "$THV" list 2>/dev/null | grep -q "$workload.*running" && break
    sleep 5
  done

  if "$THV" list 2>/dev/null | grep -q "$workload.*running"; then
    echo "    ready"
  else
    echo "    not ready - see runtime/toolhive/data/toolhive/logs/$workload.log" >&2
  fi
done

echo
"$THV" list 2>&1 | sed 's/^/  /'
echo
generate_sandbox_mcp
echo
echo "  verify with: bash tests/security/run-toolhive-tests.sh"
echo
