#!/usr/bin/env bash
# Confirm the POC introduced zero changes to the product repositories.
#
# Compares current Git state against the baseline captured at bootstrap. All three
# repos were ALREADY dirty when captured, so this asserts "nothing new changed",
# not "the repo is clean". An initially-dirty repo staying identically dirty is a
# PASS; a dirty repo becoming clean is a FAIL, because something modified it.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
set +e

printf '\nProduct repository integrity\n'

overall=0

for repo in "${REPOS[@]}"; do
  heading "$repo"

  meta="${BASELINE_DIR}/${repo}.meta"
  base_porcelain="${BASELINE_DIR}/${repo}.porcelain"

  if [[ ! -f "$meta" || ! -f "$base_porcelain" ]]; then
    bad "no baseline captured - cannot verify (run ./scripts/bootstrap.sh)"
    overall=1
    continue
  fi

  if ! path="$(repo_path "$repo")"; then
    bad "repos/$repo link is missing"
    overall=1
    continue
  fi

  base_branch="$(sed -n 's/^branch=//p' "$meta")"
  base_head="$(sed -n 's/^head=//p' "$meta")"
  now_branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  now_head="$(git -C "$path" rev-parse HEAD 2>/dev/null)"

  repo_failed=0

  if [[ "$now_branch" == "$base_branch" ]]; then
    ok "branch unchanged  $(dim "$now_branch")"
  else
    bad "branch CHANGED  $base_branch -> $now_branch"
    repo_failed=1
  fi

  if [[ "$now_head" == "$base_head" ]]; then
    ok "HEAD unchanged  $(dim "${now_head:0:12}")"
  else
    bad "HEAD CHANGED  ${base_head:0:12} -> ${now_head:0:12}"
    repo_failed=1
  fi

  now_porcelain="$(mktemp)"
  git -C "$path" status --porcelain > "$now_porcelain" 2>/dev/null

  if diff -q "$base_porcelain" "$now_porcelain" >/dev/null 2>&1; then
    ok "working tree identical to baseline  $(dim "$(wc -l < "$now_porcelain") pre-existing entries")"
  else
    bad "working tree DIFFERS from baseline"
    printf '%s\n' "$(dim '    (- baseline, + now)')"
    diff "$base_porcelain" "$now_porcelain" | sed 's/^/    /' | head -40
    repo_failed=1
  fi
  rm -f "$now_porcelain"

  # A `git stash` would hide modifications from status --porcelain, making the
  # working tree look untouched. Compare the count against the baseline so only a
  # change is reported; these repos legitimately carry many pre-existing stashes.
  base_stashes="$(sed -n 's/^stashes=//p' "$meta")"
  now_stashes="$(git -C "$path" stash list 2>/dev/null | wc -l)"
  if [[ -z "$base_stashes" ]]; then
    dim "    stash count not in baseline ($now_stashes now) - recapture to enable this check"
  elif [[ "$now_stashes" == "$base_stashes" ]]; then
    ok "stash count unchanged  $(dim "$now_stashes pre-existing")"
  else
    bad "stash count CHANGED  $base_stashes -> $now_stashes"
    repo_failed=1
  fi

  [[ $repo_failed -eq 1 ]] && overall=1
done

echo
if [[ $overall -eq 0 ]]; then
  ok "PASS - no product repository file was modified by the POC"
else
  bad "FAIL - product repository state diverged from baseline"
fi

exit $overall
