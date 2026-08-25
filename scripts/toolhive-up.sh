#!/usr/bin/env bash
#
# Starts the MCP gateway.
#
# ToolHive's own state lives under runtime/toolhive/ rather than the developer's
# XDG directories, so the gateway is reproducible, inspectable and removable with
# the repository instead of leaving state behind in a home directory.
#
# Allowlists come from config/toolhive/servers.yaml, which is the single place
# tool admission is declared. Nothing here decides what is exposed.
#
#   bash scripts/toolhive-up.sh [--stop]
#
# Servers take up to a couple of minutes to pull and become ready on first run.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export XDG_CONFIG_HOME="$ROOT/runtime/toolhive/config"
export XDG_DATA_HOME="$ROOT/runtime/toolhive/data"
export XDG_STATE_HOME="$ROOT/runtime/toolhive/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

THV="$ROOT/runtime/toolhive/bin/thv"
CONFIG="$ROOT/config/toolhive/servers.yaml"

[[ -x "$THV" ]] || { echo "thv not found at $THV" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG" >&2; exit 1; }

# Names are derived from the config rather than hardcoded so this script has no
# opinion about which servers exist.
mapfile -t ENABLED < <(python3 - "$CONFIG" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
for s in cfg.get("servers", []):
    if not s.get("enabled"):
        continue
    tools = s.get("tools") or []
    if not tools:
        # Default-deny: a server with no allowlist would expose everything.
        print(f"SKIP {s['name']} no tools allowlisted", file=sys.stderr)
        continue
    print("\t".join([
        s["name"], s.get("registry", s["name"]),
        str(s.get("proxy_port", "")), ",".join(tools),
    ]))
PY
)

if [[ "${1:-}" == "--stop" ]]; then
  echo
  echo "Stopping gateway"
  for row in "${ENABLED[@]}"; do
    name="gw-$(cut -f1 <<<"$row")"
    "$THV" stop "$name" >/dev/null 2>&1 && echo "  stopped $name" || true
    "$THV" rm "$name" >/dev/null 2>&1 || true
  done
  echo
  exit 0
fi

echo
echo "Starting MCP gateway"
echo "  state    runtime/toolhive/"
echo "  bind     127.0.0.1 (sandbox reaches it via host.docker.internal)"
echo

for row in "${ENABLED[@]}"; do
  IFS=$'\t' read -r name registry port tools <<<"$row"
  workload="gw-$name"

  if "$THV" list 2>/dev/null | grep -q "$workload.*running"; then
    echo "  already running  $workload"
    continue
  fi

  "$THV" rm "$workload" >/dev/null 2>&1 || true

  # --tools filters tools/list and refuses tools/call for anything absent.
  # --enable-audit produces the per-call evidence trail.
  # --isolate-network is ToolHive's default and is left on deliberately: the MCP
  # server gets a DNS and egress-proxy sidecar rather than open host networking.
  args=(run --name "$workload" --enable-audit)
  [[ -n "$port" ]] && args+=(--proxy-port "$port")
  while IFS= read -r t; do args+=(--tools "$t"); done < <(tr ',' '\n' <<<"$tools")
  args+=("$registry")

  echo "  starting         $workload  (${tools//,/, })"
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
    # Readiness can lag rather than fail; the log distinguishes the two.
    echo "    not ready yet - check runtime/toolhive/data/toolhive/logs/$workload.log" >&2
  fi
done

echo
"$THV" list 2>&1 | sed 's/^/  /'
echo
echo "  verify with: bash tests/security/run-toolhive-tests.sh"
echo
