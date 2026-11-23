#!/usr/bin/env bash
# Ensure nkb-agent-runtime exists and docker image inspect succeeds.
#
# Docker Desktop's containerd store sometimes leaves a tag in `docker images`
# that `docker image inspect` rejects ("No such image"). start.sh used to treat
# that as "missing" and stop; rebuilding re-exports/unpacks the layers (~seconds
# when cached).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

AGENT_IMAGE="${NKB_AGENT_IMAGE:-nkb-agent-runtime:2026.08.11-e8db854}"

if ! command -v docker >/dev/null 2>&1; then
  bad "docker not on PATH"
  exit 1
fi

if docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1; then
  exit 0
fi

inspect_err="$(docker image inspect "$AGENT_IMAGE" 2>&1 >/dev/null || true)"
listed="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fx "$AGENT_IMAGE" || true)"

if [[ -n "$listed" ]]; then
  warn "sandbox image tag listed but not inspectable; rebuilding"
elif [[ "$inspect_err" != *"No such image"* ]]; then
  warn "docker could not verify sandbox image; retrying with rebuild"
  dim "  ${inspect_err:0:120}"
else
  dim "  building $AGENT_IMAGE (first time or after prune)"
fi

if ! docker build -t "$AGENT_IMAGE" "$POC_ROOT/docker/agent-runtime"; then
  bad "docker build failed"
  exit 1
fi

if docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1; then
  exit 0
fi

bad "image still not inspectable after build"
exit 1
