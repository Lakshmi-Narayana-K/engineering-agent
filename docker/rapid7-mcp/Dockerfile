# The Rapid7 InsightIDR MCP server, containerised so ToolHive can govern it.
#
# Why this image exists at all: the server is a local checkout of a community
# project, not a published package, so there is no uvx:// or npx:// scheme
# ToolHive can resolve. An image is the only way to put it behind the gateway.
#
# And it needs to be behind the gateway more than most. Checking the source
# rather than trusting the README: of its 97 tools, 64 are annotated read-only,
# 11 are annotated destructive, and 22 carry no annotation at all - every one of
# which mutates (create_investigation, update_alert, delete_log, and so on).
# The absence of a label is the dangerous case here, which is exactly why the
# allowlist is derived from the read-only annotation rather than from names.
# Two of the unlabelled tools are called investigate_alerts and
# generate_alert_report; both write.
#
# So the trust boundary is not this code. It is ToolHive's tool admission, the
# egress policy in config/toolhive/rapid7-permissions.json, the audit log, and
# this container. The project is version 0.1.0 by a single author and holds a
# credential to our security platform - worth stating plainly rather than
# leaving implied.
#
# Build into the SYSTEM Docker daemon, not Docker Desktop's:
#
#   DOCKER_HOST=unix:///var/run/docker.sock docker build \
#     -f docker/rapid7-mcp/Dockerfile \
#     -t nkb-rapid7-mcp:0.1.0 runtime/mcp/r7-insightidr
#
# ToolHive drives /var/run/docker.sock and ignores DOCKER_HOST, so an image
# built with the default desktop-linux context is invisible to it and the
# workload fails with a pull error for an image that plainly exists locally.

FROM python:3.12-slim

# The upstream checkout is pinned by commit in config/versions.yaml. Recorded
# here as a label so a running container can be traced back to its source.
ARG SOURCE_COMMIT=b059dcd
LABEL org.opencontainers.image.source="https://github.com/rivaldofwijaya/R7-InsightIDR-MCP-Server" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      org.opencontainers.image.description="Rapid7 InsightIDR MCP server, read-only tools only"

WORKDIR /app
COPY pyproject.toml README.md LICENSE ./
COPY src ./src

# No --editable and no dev extras: this is a runtime image, and the test
# dependencies are surface we would rather not ship.
RUN set -eux; \
    pip install --no-cache-dir .; \
    mcp-insightidr --help >/dev/null 2>&1 || true

# Unprivileged. The server needs no filesystem access beyond its own code - it
# is an HTTP client to the Rapid7 API and nothing more.
RUN set -eux; \
    groupadd --gid 1002 r7; \
    useradd --uid 1002 --gid 1002 --no-create-home --shell /usr/sbin/nologin r7
USER r7

# Credentials arrive as environment variables injected by ToolHive's secrets
# provider, never baked in and never mounted.
#
# stdio, matching how ToolHive runs it: --transport stdio in scripts/toolhive-up.sh.
ENTRYPOINT ["mcp-insightidr"]
