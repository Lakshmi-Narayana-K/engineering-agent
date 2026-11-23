#!/usr/bin/env bash
exec "$(dirname "$0")/django-env-shell.sh" prod "$@"
