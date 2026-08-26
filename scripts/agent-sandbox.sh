#!/usr/bin/env bash
#
# The one place the agent's sandbox is defined.
#
# Used two ways, and that is the point: the Agent Server invokes this as its ACP
# command, and the security tests invoke it to check the boundary. A single
# definition means the thing we test is the thing that runs. If the mounts were
# duplicated in a compose file and a test harness, they would drift, and the
# tests would start proving something about a configuration nobody uses.
#
# The mount table IS the security policy for the filesystem. Cursor performs
# reads, writes and shell commands in-process without asking the ACP client, so
# no policy code of ours can gate them - what the kernel refuses is the whole of
# the protection. Read `:ro` below as "enforced", not "intended".
#
#   scripts/agent-sandbox.sh                # run as an ACP agent over stdio
#   scripts/agent-sandbox.sh --exec CMD...  # run something else inside the box
#
# Requires the workspace built by scripts/export-clean-source.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="${NKB_AGENT_IMAGE:-nkb-agent-runtime:2026.08.11-e8db854}"
WORKSPACE="$ROOT/workspace"
KEY_FILE="$ROOT/runtime/cursor/api-key"

MODE=acp
EXEC_ARGS=()
if [[ "${1:-}" == "--exec" ]]; then
  MODE=exec
  shift
  EXEC_ARGS=("$@")
  ((${#EXEC_ARGS[@]})) || { echo "--exec needs a command" >&2; exit 2; }
fi

if [[ ! -d "$WORKSPACE/repos" ]]; then
  echo "no clean workspace - run scripts/export-clean-source.sh first" >&2
  exit 1
fi
mkdir -p "$WORKSPACE/generated" "$WORKSPACE/agent-state"

# Read-only product source, read-only organisation context, one writable
# directory for output, and a tmpfs for scratch. Nothing else is reachable:
# there is no bind mount for the developer's home, ~/.aws or ~/.cursor, so
# those paths do not exist inside rather than being denied on access.
MOUNTS=(
  --mount "type=bind,source=$WORKSPACE/repos,target=/workspace/repos,readonly"
  --mount "type=bind,source=$WORKSPACE/generated,target=/workspace/generated"
  --mount "type=bind,source=$ROOT/context,target=/workspace/context,readonly"
  --mount "type=bind,source=$ROOT/knowledge,target=/workspace/knowledge,readonly"
  --mount "type=bind,source=$ROOT/AGENTS.md,target=/workspace/AGENTS.md,readonly"
  --mount "type=bind,source=$WORKSPACE/agent-state,target=/home/agent/.cursor"
  --tmpfs "/tmp:rw,noexec,nosuid,size=512m"
  # HOME itself must be writable, not just ~/.cursor. With a read-only root
  # filesystem and only ~/.cursor mounted, session creation failed with
  # "Failed to initialize session services" and no further diagnostic - Cursor
  # writes state under HOME outside .cursor as well.
  #
  # A tmpfs rather than a bind mount, because none of it should outlive the
  # session: this is scratch state, and anything worth keeping belongs in
  # ~/.cursor (bind-mounted above) or /workspace/generated. It also stays true
  # to the rule that nothing from the developer's home is visible - this HOME is
  # created empty at start and discarded at exit.
  #
  # Nested mounts resolve by path depth, so the ~/.cursor bind and ~/.cache
  # tmpfs still land inside this one.
  # mode=1777 is load-bearing: a tmpfs is created root-owned, so without it the
  # agent (uid 1001) still cannot write and the failure is identical to having
  # no tmpfs at all. That cost an hour - the visible symptom was Cursor's
  # "Failed to initialize session services", and the real error only appeared
  # when the agent was run directly: EACCES: mkdir '/home/agent/.config'.
  --tmpfs "/home/agent:rw,nosuid,size=256m,mode=1777"
)

# Cursor writes session state under $HOME/.cursor and fails to start without a
# writable path there, which the read-only root filesystem otherwise prevents.
# This is our own directory rather than a tmpfs so sessions survive the
# container, and rather than the developer's ~/.cursor so their credentials and
# project history stay outside the sandbox entirely.

# noexec on /tmp: scratch space should not become a place to stage a binary.

# The governed MCP path. ToolHive's proxy is a host process on loopback, which a
# container cannot reach, so the sandbox needs an explicit route to the host
# gateway. Without this Cursor sees no MCP servers at all and the AWS, Rapid7 and
# database capabilities disappear - which is precisely why the sandbox could not
# become the default before ToolHive existed.
#
# This does widen the sandbox's network reach to host-published ports, so it is
# worth being precise about the limit: host services bound to 127.0.0.1 are not
# reachable this way on Docker Engine, and the gateway is reachable because
# Docker Desktop proxies host.docker.internal to the host. The gateway is
# therefore the intended entry point rather than an accidental one.
NETWORK=(
  --add-host "host.docker.internal:host-gateway"
)

HARDENING=(
  --user 1001:1001
  --cap-drop ALL
  --security-opt no-new-privileges
  --pids-limit 512
  --memory 4g
  --read-only                      # container filesystem itself; mounts above stay writable
  --tmpfs "/home/agent/.cache:rw,size=1g"
)

# --read-only plus an explicit cache tmpfs: Cursor needs a writable compile
# cache and nothing else, so the rest of the root filesystem is immutable.

ENV_ARGS=()
# The Cursor credential goes to the Cursor process and nowhere else. AWS and
# database credentials are deliberately NOT passed: those belong to the MCP
# runtimes, which sit outside this sandbox.
if [[ -s "$KEY_FILE" ]]; then
  ENV_ARGS+=(--env "CURSOR_API_KEY=$(tr -d '\n' < "$KEY_FILE")")
elif [[ -n "${CURSOR_API_KEY:-}" ]]; then
  ENV_ARGS+=(--env "CURSOR_API_KEY=$CURSOR_API_KEY")
fi

if [[ "$MODE" == exec ]]; then
  exec docker run --rm -i \
    "${MOUNTS[@]}" "${NETWORK[@]}" "${HARDENING[@]}" "${ENV_ARGS[@]}" \
    --entrypoint /bin/bash \
    "$IMAGE" -c 'exec "$@"' _ "${EXEC_ARGS[@]}"
fi

# ACP is a stdio protocol: the Agent Server writes requests on stdin and reads
# responses on stdout, so nothing may be printed here that is not protocol.
#
# --trust answers Cursor's workspace-trust prompt, which otherwise blocks
# session creation with no way to respond over ACP. It is worth being precise
# about what it does and does not do: it marks the directory as trusted, and
# nothing more. It is NOT --force/--yolo, which would allow commands without
# asking - those stay off, so the permission prompts the ACP policy layer exists
# to answer still happen.
#
# Trusting this directory is not a concession: it is our own export, mounted
# read-only, containing only tracked product source that was filtered for
# credentials on the way in.
exec docker run --rm -i \
  "${MOUNTS[@]}" "${NETWORK[@]}" "${HARDENING[@]}" "${ENV_ARGS[@]}" \
  --entrypoint /usr/local/bin/agent \
  "$IMAGE" --trust acp
