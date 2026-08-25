#!/usr/bin/env bash
#
# Isolation checks executed INSIDE the sandbox, where the answer counts.
#
# The host-side version of these checks measures the developer's machine, which
# tells us nothing about what the agent can reach. This script runs in the same
# container, as the same user, under the same mounts as a real session, so a
# pass here is a statement about the boundary the agent actually faces.
#
# Invoked via `scripts/agent-sandbox.sh --exec bash /workspace/... ` by
# run-isolation-tests.sh. Emits one `RESULT <state> <name> <detail>` line per
# check for the caller to parse, so formatting stays outside.

set -uo pipefail

pass() { echo "RESULT closed $1 :: $2"; }
gap()  { echo "RESULT open   $1 :: $2"; }

# --- product source must be read-only at the kernel, not by convention -------
for repo in nkb_backend nkb_assessment_backend nkb_learning_backend; do
  dir="/workspace/repos/$repo"
  if [[ ! -d "$dir" ]]; then
    gap "$repo present" "not mounted"
    continue
  fi
  # An actual write attempt: access(2) can disagree with the mount for root or
  # with some storage drivers, and this is the claim that matters most.
  if touch "$dir/.nkb-write-probe" 2>/dev/null; then
    rm -f "$dir/.nkb-write-probe" 2>/dev/null
    gap "$repo read-only" "WRITE SUCCEEDED"
  else
    pass "$repo read-only" "write refused by kernel"
  fi
done

# --- excluded credential files must be absent, not merely unreadable ---------
CREDS=$(find /workspace/repos \
          \( -name '*env_prod*' -o -name '*service_account*' -o -name '*.pem' \
             -o -name 'credentials.json' -o -name '.env' \) 2>/dev/null | wc -l)
if [[ "$CREDS" -eq 0 ]]; then
  pass "credential files absent" "none in the workspace"
else
  gap "credential files absent" "$CREDS present"
fi

# --- developer machine state must not exist inside ---------------------------
if [[ -e "$HOME/.aws" ]]; then
  gap "host AWS config absent" "present at \$HOME/.aws"
else
  pass "host AWS config absent" "not present"
fi

# The MCP config needs a sharper test than presence, because there is now
# legitimately one: ours, generated to point at the ToolHive gateway. What must
# NOT be here is the host's config, which spawns MCP servers directly with
# `command` and `env` blocks carrying credential placeholders. So the check is
# whether any server is defined as a local process rather than a gateway URL -
# the difference between governed and ungoverned MCP access.
MCP_CFG="$HOME/.cursor/mcp.json"
if [[ ! -f "$MCP_CFG" ]]; then
  pass "no ungoverned MCP config" "no mcp.json present"
elif grep -qE '"(command|args|env)"[[:space:]]*:' "$MCP_CFG"; then
  gap "no ungoverned MCP config" "mcp.json spawns servers directly, bypassing the gateway"
elif grep -q '"url"' "$MCP_CFG"; then
  pass "no ungoverned MCP config" "gateway URLs only, no direct server spawning"
else
  pass "no ungoverned MCP config" "no servers defined"
fi

# The developer's home is /home/<user> on the host; inside, HOME is the
# container's own. Finding host paths at all would mean a bind mount leaked.
if [[ -d /host || -d /Users || -e /home/nxtwave ]]; then
  gap "host home not mounted" "a host home path is visible"
else
  pass "host home not mounted" "no host home visible"
fi

# --- the AWS CLI is a bypass around MCP, ToolHive and their audit trails -----
if command -v aws >/dev/null 2>&1; then
  gap "aws cli absent" "on PATH at $(command -v aws)"
else
  pass "aws cli absent" "not installed"
fi

# --- credentials that belong to other components must not be here ------------
LEAKED=""
for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE DB_PASSWORD; do
  [[ -n "${!var:-}" ]] && LEAKED="$LEAKED $var"
done
if [[ -z "$LEAKED" ]]; then
  pass "no foreign credentials in env" "AWS and DB variables unset"
else
  gap "no foreign credentials in env" "set:$LEAKED"
fi

# --- output must be writable, or an investigation cannot record anything -----
if touch /workspace/generated/.nkb-write-probe 2>/dev/null; then
  rm -f /workspace/generated/.nkb-write-probe
  pass "generated dir writable" "writable as expected"
else
  gap "generated dir writable" "not writable"
fi

# --- context must be readable and not writable -------------------------------
if [[ -r /workspace/AGENTS.md ]]; then
  if touch /workspace/AGENTS.md 2>/dev/null; then
    gap "context read-only" "AGENTS.md is writable"
  else
    pass "context read-only" "readable, not writable"
  fi
else
  gap "context read-only" "AGENTS.md not readable"
fi
