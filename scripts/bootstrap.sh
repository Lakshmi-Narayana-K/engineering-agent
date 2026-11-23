#!/usr/bin/env bash
# One-time setup: verify prerequisites, link the repositories, capture the Git
# baseline. Safe to re-run; it will not overwrite an existing baseline unless
# --recapture is passed.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

RECAPTURE=0
[[ "${1:-}" == "--recapture" ]] && RECAPTURE=1

failures=0

heading "Prerequisites"

for tool in node npm python3 curl git agent agent-canvas; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool  $(dim "$(command -v "$tool")")"
  else
    bad "$tool not found"
    failures=$((failures + 1))
  fi
done

node_major="$(node --version 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')"
if [[ -n "$node_major" && "$node_major" -ge 22 ]]; then
  ok "node $(node --version) meets the >=22.12.0 requirement"
else
  bad "node >= 22.12.0 required for @openhands/agent-canvas"
  failures=$((failures + 1))
fi

if agent acp --help >/dev/null 2>&1; then
  ok "cursor ACP available  $(dim "$(agent --version 2>/dev/null)")"
else
  bad "'agent acp' unavailable - upgrade Cursor CLI"
  failures=$((failures + 1))
fi

if agent status 2>/dev/null | grep -qi "logged in"; then
  ok "cursor CLI authenticated"
else
  warn "cursor CLI may not be logged in - run 'agent login'"
fi

heading "Repository links"

# REPOS and REPO_SOURCES come from _common.sh so the links, the clean export and
# the baseline check all read the same list.
mkdir -p "${POC_ROOT}/repos" "$BASELINE_DIR" "$LOG_DIR"

for repo in "${REPOS[@]}"; do
  src="${REPO_SOURCES[$repo]}"
  if [[ ! -d "$src/.git" ]]; then
    bad "$repo: not a git checkout at $src"
    failures=$((failures + 1))
    continue
  fi
  ln -sfn "$src" "${POC_ROOT}/repos/${repo}"
  ok "repos/$repo -> $src"
done

heading "Git baseline"

for repo in "${REPOS[@]}"; do
  path="$(repo_path "$repo")" || { bad "$repo: link missing"; failures=$((failures+1)); continue; }
  meta="${BASELINE_DIR}/${repo}.meta"

  if [[ -f "$meta" && $RECAPTURE -eq 0 ]]; then
    dim "  $repo: baseline already captured (use --recapture to refresh)"
    continue
  fi

  {
    echo "repo=$repo"
    echo "path=$path"
    echo "branch=$(git -C "$path" rev-parse --abbrev-ref HEAD)"
    echo "head=$(git -C "$path" rev-parse HEAD)"
    echo "stashes=$(git -C "$path" stash list | wc -l)"
    echo "captured_at=$(date -Iseconds)"
  } > "$meta"
  git -C "$path" status --porcelain > "${BASELINE_DIR}/${repo}.porcelain"
  ok "$repo  $(dim "branch=$(git -C "$path" rev-parse --abbrev-ref HEAD) dirty=$(wc -l < "${BASELINE_DIR}/${repo}.porcelain")")"
done

heading "ACP proxy chain"
if [[ -f "$SHIM" ]]; then
  ok "runtime/acp-policy-proxy + runtime/cursor-compat-proxy present"
else
  bad "ACP policy proxy missing at $SHIM"
  failures=$((failures + 1))
fi

echo
if [[ $failures -eq 0 ]]; then
  ok "bootstrap complete - run ./scripts/start.sh"
else
  bad "bootstrap finished with $failures problem(s)"
  exit 1
fi
