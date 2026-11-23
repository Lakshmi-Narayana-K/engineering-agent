#!/usr/bin/env bash
# Host-side check: django-prod-host-worker consumes a job and runs manage.py shell.
# Usage: django-prod-ping.sh [prod|beta|all]   (default: prod)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="$ROOT/runtime/django-jobs"
NKB_ROOT="$(readlink -f "$ROOT/repos/nkb_backend" 2>/dev/null || true)"
PY="${NKB_ROOT}/.venv/bin/python"
TIMEOUT="${DJANGO_PROD_PING_TIMEOUT:-90}"
TARGET="${1:-prod}"

[[ -x "$PY" && -f "$NKB_ROOT/manage.py" ]] || exit 1
[[ -f "$ROOT/runtime/django-prod-worker.pid" ]] \
  && kill -0 "$(cat "$ROOT/runtime/django-prod-worker.pid")" 2>/dev/null || exit 1

ping_one() {
  local env_name="$1"
  local marker="DJANGO_${env_name^^}_PING_OK"
  local id="ping${env_name}$$$(date +%s%N)"
  local req="$JOBS/${id}.req"
  local out="$JOBS/${id}.out"
  local err="$JOBS/${id}.err"
  local done="$JOBS/${id}.done"
  rm -f "$out" "$err" "$done"
  {
    echo "__ENV__${env_name}"
    printf '%s\n' "print('${marker}')"
  } >"$req"
  chmod 666 "$req" 2>/dev/null || true

  local deadline=$((SECONDS + TIMEOUT))
  while [[ ! -f "$done" ]]; do
    if (( SECONDS >= deadline )); then
      rm -f "$req"
      return 1
    fi
    sleep 0.25
  done

  grep -q "$marker" "$out" 2>/dev/null || return 1
  rm -f "$out" "$err" "$done"
  return 0
}

mkdir -p "$JOBS"
chmod 1777 "$JOBS" 2>/dev/null || true

case "$TARGET" in
  prod) ping_one prod ;;
  beta) ping_one beta ;;
  all)
    ping_one prod && ping_one beta
    ;;
  *)
    echo "usage: django-prod-ping.sh [prod|beta|all]" >&2
    exit 2
    ;;
esac
