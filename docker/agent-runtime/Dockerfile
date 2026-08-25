# The sandbox the agent runs inside.
#
# This image is a security boundary, not a convenience. The finding that forced
# it: Cursor never routes file reads, file writes, or terminal calls through the
# ACP client - across 3MB of recorded traffic it used fs/read_text_file,
# fs/write_text_file and terminal/create zero times against 49 permission
# requests. It acts in-process and merely asks first. So no ACP proxy of ours
# can gate those operations, and the only thing that can is the boundary the
# kernel enforces: what is mounted, and how.
#
# Two rules follow, and both are load-bearing:
#
#   1. Nothing from the developer's machine is baked in or mounted. HOME lives
#      inside the container, so host ~/.aws and ~/.cursor are not merely
#      ignored, they are absent. Compare the old approach, where the shim
#      redirected HOME and deleted AWS variables at spawn time - correct, but
#      dependent on our code running correctly first.
#
#   2. The AWS CLI is deliberately not installed. It is an entire bypass path
#      around MCP, ToolHive and their audit trails, and the agent does not need
#      it to investigate application code. Absence beats a deny rule.
#
# Cursor bundles its own node, ripgrep and sandbox helper, so the base image
# supplies little beyond a libc and CA certificates.

ARG NODE_VERSION=22.23-bookworm-slim
FROM node:${NODE_VERSION}

# Pinned deliberately. The installer at cursor.com/install resolves to whatever
# is current, which would make image builds non-reproducible; the download URL
# it uses is version-addressed, so we call that directly instead.
ARG CURSOR_VERSION=2026.08.11-e8db854
ARG TARGETARCH=amd64

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        procps; \
    rm -rf /var/lib/apt/lists/*

# git is present so the agent can read repository metadata, not write it. The
# workspace is mounted read-only, so fetch/push have nothing to act on.

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) cursor_arch=x64 ;; \
        arm64) cursor_arch=arm64 ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/cursor-agent; \
    curl -fSL "https://downloads.cursor.com/lab/${CURSOR_VERSION}/linux/${cursor_arch}/agent-cli-package.tar.gz" \
      | tar --strip-components=1 -xzf - -C /opt/cursor-agent; \
    ln -s /opt/cursor-agent/cursor-agent /usr/local/bin/agent; \
    /opt/cursor-agent/cursor-agent --version

# Unprivileged, and owning nothing it does not need. The node image ships a
# `node` user; a distinct one makes the audit trail unambiguous.
RUN set -eux; \
    groupadd --gid 1001 agent; \
    useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash agent

# Written to at runtime by the agent, so it must exist and be owned before the
# read-only mounts land on top of the rest of /workspace.
RUN set -eux; \
    mkdir -p /workspace/generated /home/agent/.cursor; \
    chown -R agent:agent /workspace /home/agent

USER agent
ENV HOME=/home/agent \
    XDG_CACHE_HOME=/home/agent/.cache \
    NODE_COMPILE_CACHE=/home/agent/.cache/cursor-compile-cache
WORKDIR /workspace

# No CMD that starts a server: this image is invoked as an ACP agent over stdio
# by the Agent Server, one process per session, and exits with the session.
ENTRYPOINT ["/usr/local/bin/agent"]
CMD ["acp"]
