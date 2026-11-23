#!/usr/bin/env bash
# Read-only Django ORM/shell for prod or beta (host worker + env_prod / env_beta).
set -euo pipefail

ENV_NAME="${1:?usage: django-env-shell.sh prod|beta [-c code | -f path]}"
shift

case "$ENV_NAME" in
  prod)
    ENV_FILE="/workspace/secrets/prod-django.env"
    ENABLED_FLAG="/workspace/secrets/.prod-django-enabled"
    LABEL="django-prod-shell"
    ;;
  beta)
    ENV_FILE="/workspace/secrets/beta-django.env"
    ENABLED_FLAG="/workspace/secrets/.beta-django-enabled"
    LABEL="django-beta-shell"
    ;;
  *)
    echo "django-env-shell: unknown environment '$ENV_NAME' (use prod or beta)" >&2
    exit 2
    ;;
esac

APP_ROOT="/workspace/repos/nkb_backend"
SITE_PACKAGES="/workspace/nkb-venv/lib/python3.12/site-packages"
JOBS="/workspace/django-jobs"
TIMEOUT_SEC="${DJANGO_PROD_JOB_TIMEOUT:-300}"

usage() {
  echo "usage: $LABEL -c 'python statements' | $LABEL -f /workspace/generated/script.py" >&2
  exit 2
}

run_via_host_worker() {
  local mode="$1"
  local payload="$2"
  [[ -d "$JOBS" && -f "$ENABLED_FLAG" ]] || return 1

  local id="job$$$(date +%s%N)"
  local req="$JOBS/${id}.req"
  local out="$JOBS/${id}.out"
  local err="$JOBS/${id}.err"
  local done="$JOBS/${id}.done"

  rm -f "$out" "$err" "$done"
  {
    echo "__ENV__${ENV_NAME}"
    if [[ "$mode" == "file" ]]; then
      echo __FILE__
      echo "$payload"
    else
      printf '%s' "$payload"
    fi
  } >"$req"

  local deadline=$((SECONDS + TIMEOUT_SEC))
  while [[ ! -f "$done" ]]; do
    if (( SECONDS >= deadline )); then
      if [[ -f "$JOBS/${id}.processing" ]]; then
        echo "${LABEL}: worker is running but the query exceeded ${TIMEOUT_SEC}s (slow query, not a connection problem). Do not retry the same query; narrow it or use an estimate." >&2
      else
        echo "${LABEL}: no host worker picked up the job in ${TIMEOUT_SEC}s; the Canvas host operator must re-run start-local-shared.sh" >&2
      fi
      rm -f "$req"
      return 1
    fi
    sleep 0.25
  done

  [[ -f "$out" ]] && cat "$out"
  if [[ -s "$err" ]]; then
    cat "$err" >&2
  fi
  rm -f "$out" "$err" "$done"
  return 0
}

resolve_python() {
  if [[ -x /usr/bin/python3.12 ]] && /usr/bin/python3.12 -c 'import sys' 2>/dev/null; then
    echo /usr/bin/python3.12
    return 0
  fi
  if [[ -x /workspace/nkb-venv/bin/python ]] \
    && /workspace/nkb-venv/bin/python -c 'import sys' 2>/dev/null; then
    echo /workspace/nkb-venv/bin/python
    return 0
  fi
  return 1
}

try_in_container() {
  [[ -f "$ENV_FILE" && -f "$APP_ROOT/manage.py" ]] || return 1
  local py
  py="$(resolve_python)" || return 1
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  cd "$APP_ROOT"
  export PYTHONPATH="${SITE_PACKAGES}${PYTHONPATH:+:${PYTHONPATH}}"
  if [[ "$1" == "-c" ]]; then
    exec "$py" manage.py shell -c "$2"
  fi
  exec "$py" manage.py shell <"$2"
}

[[ -f "$ENV_FILE" && -f "$APP_ROOT/manage.py" ]] || {
  echo "${LABEL} is not enabled on this host (run start-local-shared.sh)" >&2
  exit 1
}

HOST_WORKER_MODE=0
[[ -f "$ENABLED_FLAG" ]] && HOST_WORKER_MODE=1

if [[ "${1:-}" == "-c" && -n "${2:-}" ]]; then
  if [[ "$HOST_WORKER_MODE" -eq 1 ]]; then
    run_via_host_worker code "$2" && exit 0
  else
    try_in_container -c "$2" 2>/dev/null && exit 0
    run_via_host_worker code "$2" && exit 0
  fi
  echo "${LABEL}: host worker failed (see runtime/logs/django-prod-worker.log on the Canvas host)" >&2
  exit 1
fi

if [[ "${1:-}" == "-f" && -n "${2:-}" && -f "${2}" ]]; then
  if [[ "$HOST_WORKER_MODE" -eq 1 ]]; then
    run_via_host_worker file "$2" && exit 0
  else
    try_in_container -f "$2" 2>/dev/null && exit 0
    run_via_host_worker file "$2" && exit 0
  fi
  echo "${LABEL}: host worker failed (see runtime/logs/django-prod-worker.log on the Canvas host)" >&2
  exit 1
fi

usage
