#!/usr/bin/env bash
#
# Installs the pinned ToolHive CLI into the workspace.
#
# Kept inside runtime/toolhive/ rather than on the system PATH so the version is
# tied to this repository and removable with it - two checkouts can run
# different ToolHive versions without interfering, and nothing is left behind on
# the developer's machine.
#
# The binary is 124MB and therefore not committed. This script reproduces it
# from the pinned version, with the release checksum verified before use: the
# gateway is a security boundary, so silently running a different build than
# intended is not acceptable.
#
#   bash scripts/toolhive-install.sh
#
# Version is read from config/versions.yaml, the single source of truth.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(python3 -c "
import yaml
cfg = yaml.safe_load(open('config/versions.yaml'))
v = (cfg.get('toolhive') or {}).get('version', '')
print('' if not v or 'NOT YET' in str(v) else v)
" 2>/dev/null)"

if [[ -z "$VERSION" ]]; then
  echo "no pinned toolhive version in config/versions.yaml" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

DEST="$ROOT/runtime/toolhive"
BIN="$DEST/bin/thv"
TARBALL="toolhive_${VERSION}_linux_${ARCH}.tar.gz"
BASE="https://github.com/stacklok/toolhive/releases/download/v${VERSION}"

if [[ -x "$BIN" ]] && "$BIN" version 2>/dev/null | grep -q "$VERSION"; then
  echo "  toolhive v$VERSION already installed"
  exit 0
fi

mkdir -p "$DEST/bin"
cd "$DEST"

echo
echo "Installing ToolHive v$VERSION ($ARCH)"

curl -fSL --progress-bar -o "$TARBALL" "$BASE/$TARBALL"
curl -fsSL -o checksums.txt "$BASE/toolhive_${VERSION}_checksums.txt"

# Fail closed: an unverified gateway binary is worse than no gateway.
if ! sha256sum -c checksums.txt --ignore-missing 2>&1 | grep -q "$TARBALL: OK"; then
  echo "  CHECKSUM MISMATCH - refusing to install" >&2
  rm -f "$TARBALL"
  exit 1
fi
echo "  checksum verified"

tar -xzf "$TARBALL" -C bin thv
chmod +x bin/thv

echo "  installed $("$BIN" version 2>/dev/null | head -1) at runtime/toolhive/bin/thv"
echo
