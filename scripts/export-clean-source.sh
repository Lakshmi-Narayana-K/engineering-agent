#!/usr/bin/env bash
#
# Builds the clean source workspace the agent is allowed to see.
#
# Why this exists: the agent has been pointed at the developer's working copies,
# which contain committed credential files. A clean `git clone` does NOT fix
# that - the files are tracked, so a clone reproduces them, and their history
# reproduces them even if the tip does not. The only export that excludes them
# is one that takes the tree without the history and filters on the way out.
#
# So: `git archive HEAD` piped through `tar --exclude-from`, which means excluded
# files are never written rather than written and then removed. There is no
# window in which they exist on disk.
#
# The cost is real and worth stating: no .git directory, so the agent cannot run
# `git log` or `git blame`. Shipping .git would ship the secrets in history. As
# partial compensation each repo gets a _git-metadata.txt with branch, HEAD and
# recent commit subjects, which answers most "when did this change" questions
# without shipping the objects. Full history becomes available only once the
# product teams purge and rotate those credentials.
#
#   bash scripts/export-clean-source.sh [--out <dir>]
#
# Default output is workspace/repos/. Exits non-zero if the guarantee fails.

# REPOS comes from _common.sh. It was duplicated here until the Drops repos were
# added and the two lists disagreed: the symlinks had five repositories and the
# export produced three, which is the failure mode that looks like a missing
# file rather than a configuration error.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ROOT="$POC_ROOT"
cd "$ROOT"

OUT="$ROOT/workspace/repos"
if [[ "${1:-}" == "--out" ]]; then OUT="${2:?--out needs a directory}"; fi

EXCLUDES="$ROOT/config/workspace-exclude.txt"
LOG_DEPTH=200

[[ -f "$EXCLUDES" ]] || { echo "missing $EXCLUDES" >&2; exit 1; }

# tar wants one --exclude per pattern; comments and blanks are stripped.
mapfile -t PATTERNS < <(grep -vE '^\s*(#|$)' "$EXCLUDES")
((${#PATTERNS[@]})) || { echo "no patterns in $EXCLUDES" >&2; exit 1; }
TAR_ARGS=()
for p in "${PATTERNS[@]}"; do TAR_ARGS+=(--exclude="$p"); done

echo
echo "Exporting clean source to $OUT"
echo "  ${#PATTERNS[@]} exclusion patterns"
echo

mkdir -p "$OUT"
MANIFEST="$OUT/../manifest.txt"
: > "$MANIFEST"
{
  echo "# Clean source export"
  echo "# generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# tree only, no history - see scripts/export-clean-source.sh"
  echo
} >> "$MANIFEST"

TOTAL_LEAKS=0

for repo in "${REPOS[@]}"; do
  src="$(readlink -f "repos/$repo" 2>/dev/null || true)"
  if [[ -z "$src" || ! -d "$src/.git" ]]; then
    echo "  skip  $repo (no git repository at repos/$repo)"
    continue
  fi

  dest="$OUT/$repo"
  rm -rf "$dest"
  mkdir -p "$dest"

  # Reading from the product repo, writing only into our own workspace.
  git -C "$src" archive HEAD | tar -x "${TAR_ARGS[@]}" -C "$dest"

  head="$(git -C "$src" rev-parse HEAD)"
  branch="$(git -C "$src" rev-parse --abbrev-ref HEAD)"

  # Metadata instead of history. Subjects only: commit bodies sometimes carry
  # pasted configuration.
  {
    echo "repository : $repo"
    echo "branch     : $branch"
    echo "head       : $head"
    echo "exported   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "This is a tree export with no .git directory, so git commands will not"
    echo "work here. The last $LOG_DEPTH commit subjects follow."
    echo
    git -C "$src" log -n "$LOG_DEPTH" --format='%h %ad %an%n    %s' --date=short
  } > "$dest/_git-metadata.txt"

  # The guarantee, verified rather than assumed. If any excluded pattern
  # survived, the export is unsafe and must not be used.
  leaks=0
  while IFS= read -r pattern; do
    n=$(find "$dest" -name "$pattern" 2>/dev/null | wc -l)
    leaks=$((leaks + n))
  done < <(printf '%s\n' "${PATTERNS[@]}")

  files=$(find "$dest" -type f | wc -l)
  size=$(du -sh "$dest" | cut -f1)
  TOTAL_LEAKS=$((TOTAL_LEAKS + leaks))

  if ((leaks)); then
    printf '  FAIL  %-26s %6s files  %6s  %d excluded file(s) survived\n' \
      "$repo" "$files" "$size" "$leaks"
  else
    printf '  ok    %-26s %6s files  %6s  clean\n' "$repo" "$files" "$size"
  fi

  printf '%-26s %s  %s  %s files\n' "$repo" "$branch" "${head:0:12}" "$files" >> "$MANIFEST"
done

echo
if ((TOTAL_LEAKS)); then
  echo "  EXPORT UNSAFE - $TOTAL_LEAKS excluded file(s) present. Not usable as a workspace." >&2
  exit 1
fi

echo "  export clean, manifest at $MANIFEST"
echo
