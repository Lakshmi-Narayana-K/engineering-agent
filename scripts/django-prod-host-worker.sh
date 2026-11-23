#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="$ROOT/runtime/django-jobs"
NKB_ROOT="$(readlink -f "$ROOT/repos/nkb_backend" 2>/dev/null || true)"
PY="${NKB_ROOT}/.venv/bin/python"
# Hard cap per query. Must stay <= the client wait in django-env-shell so a slow
# query reports a clear timeout instead of leaving the agent polling a dead job.
JOB_MAX_SEC="${DJANGO_PROD_JOB_MAX_SEC:-280}"

PROD_ENV="$(tr -d '\n' <"$ROOT/runtime/prod-django-env.path" 2>/dev/null || true)"
BETA_ENV="$(tr -d '\n' <"$ROOT/runtime/beta-django-env.path" 2>/dev/null || true)"

[[ -x "$PY" && -f "$NKB_ROOT/manage.py" ]] || {
  echo "django-prod-host-worker: missing venv or manage.py" >&2
  exit 1
}
if [[ ! -f "$PROD_ENV" && ! -f "$BETA_ENV" ]]; then
  echo "django-prod-host-worker: no prod-django-env.path or beta-django-env.path" >&2
  exit 1
fi

mkdir -p "$JOBS"
chmod 1777 "$JOBS" 2>/dev/null || true

log() {
  echo "$(date -Iseconds) $*" >>"$ROOT/runtime/logs/django-prod-worker.log"
}

host_path_from_sandbox() {
  local p="$1"
  case "$p" in
    /workspace/generated/*) echo "$ROOT/workspace/generated/${p#/workspace/generated/}" ;;
    /workspace/repos/*) echo "$ROOT/workspace/repos/${p#/workspace/repos/}" ;;
    *) echo "$p" ;;
  esac
}

run_job() {
  local id="$1" req="$2"
  local out="$JOBS/${id}.out" err="$JOBS/${id}.err"
  local started=$SECONDS rc=0
  local env_name="prod"
  local env_file="$PROD_ENV"
  local first
  rm -f "$out" "$err"

  first="$(head -1 "$req" 2>/dev/null || true)"
  if [[ "$first" == __ENV__* ]]; then
    env_name="${first#__ENV__}"
    tail -n +2 "$req" >"${req}.body"
    mv "${req}.body" "$req"
  fi
  case "$env_name" in
    prod) env_file="$PROD_ENV" ;;
    beta) env_file="$BETA_ENV" ;;
    *)
      echo "unknown environment: $env_name (use prod or beta)" >"$err"
      chmod a+r "$err" 2>/dev/null || true
      touch "$JOBS/${id}.done"
      chmod a+r "$JOBS/${id}.done" 2>/dev/null || true
      rm -f "$req"
      return 0
      ;;
  esac
  if [[ ! -f "$env_file" ]]; then
    echo "django-${env_name}-shell: env file not configured on host ($env_file)" >"$err"
    chmod a+r "$err" 2>/dev/null || true
    touch "$JOBS/${id}.done"
    chmod a+r "$JOBS/${id}.done" 2>/dev/null || true
    rm -f "$req"
    return 0
  fi

  log "start $id env=$env_name"
  (
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
    cd "$NKB_ROOT"
    if [[ "$(head -1 "$req")" == "__FILE__" ]]; then
      script="$(host_path_from_sandbox "$(sed -n '2p' "$req")")"
      if [[ ! -f "$script" ]]; then
        echo "missing script: $script (from sandbox path $(sed -n '2p' "$req"))" >"$err"
        exit 0
      fi
      timeout --kill-after=10 "$JOB_MAX_SEC" "$PY" manage.py shell <"$script" >"$out" 2>"$err"
    else
      timeout --kill-after=10 "$JOB_MAX_SEC" "$PY" manage.py shell -c "$(cat "$req")" >"$out" 2>"$err"
    fi
  ) || rc=$?
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    echo "django-${env_name}-shell: query killed after ${JOB_MAX_SEC}s. Likely a full scan of a large table; use a filtered/indexed query or an estimate (information_schema.TABLES.TABLE_ROWS)." >>"$err"
  fi
  rm -f "$req"
  chmod a+r "$out" "$err" 2>/dev/null || true
  touch "$JOBS/${id}.done"
  chmod a+r "$JOBS/${id}.done" 2>/dev/null || true
  log "done $id env=$env_name rc=$rc $((SECONDS - started))s"
}

while true; do
  shopt -s nullglob
  for req in "$JOBS"/*.req; do
    [[ -f "$req" ]] || continue
    id="$(basename "$req" .req)"
    processing="$JOBS/${id}.processing"
    mv "$req" "$processing" 2>/dev/null || continue
    # Background so one slow query does not starve every other teammate's job.
    run_job "$id" "$processing" &
  done
  shopt -u nullglob
  sleep 0.25
done
