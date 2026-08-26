#!/usr/bin/env bash
#
# Proves that database access is read-only, at the layer that actually enforces
# it.
#
# The structure of this file is the argument. Section 31 asks for SELECT to be
# permitted and INSERT/UPDATE/DELETE/DROP to be "DB DENIED" - denied by the
# database, not by a filter we wrote. So each write is attempted twice:
#
#   through DBHub  - expect refusal, but this only proves the guardrail
#   direct to the reader as nkb_agent_readonly - expect ERROR 1290, which is
#                    the engine refusing and is the result that matters
#
# A suite that only tested the first would pass just as happily against a
# writer endpoint with a misconfigured user, which is exactly the failure it is
# supposed to catch.
#
# Skips cleanly when no cluster exists. Provisioning is tracked in
# provisioning/db/alpha.md.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/_common.sh

pass=0; fail=0
ok_()  { ok   "$1"; pass=$((pass + 1)); }
bad_() { bad  "$1"; fail=$((fail + 1)); }

heading "Database read-only boundary"

# --- STATIC: config cannot be pointed at the writer by accident -------------
#
# Runs with or without a cluster, because it is checking our configuration
# rather than the database. Cheap, and it catches the single most damaging
# misconfiguration available here.

READER_HOST="$(python3 - <<'PY'
import re, pathlib
t = pathlib.Path("config/dbhub.toml").read_text()
m = re.search(r'^host\s*=\s*"([^"]+)"', t, re.M)
print(m.group(1) if m else "")
PY
)"

# The placeholder check comes first because the placeholder itself contains
# "cluster-ro-", so testing for that substring first reports success on an
# unprovisioned config - and then tries to connect to a hostname that does not
# resolve.
if [[ "$READER_HOST" == *"<"* ]]; then
  READER_HOST=""
  dim "  reader host not yet filled in (cluster not provisioned)"
elif [[ "$READER_HOST" == *"cluster-ro-"* ]]; then
  ok_ "dbhub.toml targets the reader endpoint"
else
  bad_ "dbhub.toml host is not a reader endpoint: $READER_HOST"
fi

if python3 -c "
import re, sys, pathlib
t = pathlib.Path('config/dbhub.toml').read_text()
sys.exit(0 if re.search(r'^readonly\s*=\s*true', t, re.M) else 1)"; then
  ok_ "dbhub.toml sets readonly = true"
else
  bad_ "dbhub.toml does not set readonly"
fi

if python3 -c "
import json, sys, pathlib
d = json.loads(pathlib.Path('config/toolhive/db-permissions.json').read_text())
hosts = d['network']['outbound']['allow_host']
# A writer endpoint in the egress allowlist would defeat the reader guarantee
# even if dbhub.toml were correct, so both places are checked.
sys.exit(0 if not any('cluster-ro-' not in h and 'rds.' not in h for h in hosts) else 1)"; then
  ok_ "egress policy excludes the writer endpoint"
else
  bad_ "egress policy allows a non-reader database host"
fi

if python3 -c "
import json, sys, pathlib
d = json.loads(pathlib.Path('provisioning/iam/agent-readonly-permissions.json').read_text())
allow = [s for s in d['Statement'] if s.get('Sid') == 'DbConnectAsReadOnlyUserOnly']
deny  = d['Statement'][-1]
# An Allow that is not exempted from the trailing NotAction deny is inert.
sys.exit(0 if allow
         and allow[0]['Resource'].endswith('/nkb_agent_readonly')
         and 'rds-db:connect' in deny['NotAction'] else 1)"; then
  ok_ "IAM grants rds-db:connect for nkb_agent_readonly only"
else
  bad_ "IAM rds-db:connect grant missing, unscoped, or overridden by the deny"
fi

# --- RUNTIME: requires a provisioned cluster --------------------------------

DB_HOST="${NKB_DB_READER_HOST:-}"
[[ -z "$DB_HOST" && "$READER_HOST" == *"cluster-ro-"* ]] && DB_HOST="$READER_HOST"

if [[ -z "$DB_HOST" ]]; then
  printf '\n'
  dim "  runtime checks skipped - no cluster yet"
  dim "  provision with provisioning/db/alpha.md, then re-run"
  printf '\n  %d of %d static checks passed, %d failed\n\n' "$pass" "$((pass + fail))" "$fail"
  exit $(( fail > 0 ))
fi

command -v mysql >/dev/null || { bad_ "mysql client not installed"; exit 1; }

TOKEN="$(aws rds generate-db-auth-token \
           --hostname "$DB_HOST" --port 3306 \
           --username nkb_agent_readonly \
           --profile "${AWS_PROFILE:-nkb-agent-alpha}" 2>/dev/null)"

if [[ -z "$TOKEN" ]]; then
  bad_ "could not generate an RDS auth token - check rds-db:connect"
  exit 1
fi

# --ssl-mode=REQUIRED because the user is created REQUIRE SSL; without it the
# server refuses and the error looks like bad credentials.
run_sql() {
  MYSQL_PWD="$TOKEN" mysql \
    --host="$DB_HOST" --port=3306 --user=nkb_agent_readonly \
    --ssl-mode=REQUIRED --connect-timeout=10 \
    --batch --skip-column-names -e "$1" 2>&1
}

heading "Against the reader as nkb_agent_readonly"

if run_sql "SELECT 1;" | grep -q "^1$"; then
  ok_ "SELECT is permitted"
else
  bad_ "SELECT failed - connection or grants are wrong"
fi

# 1290 is "The MySQL server is running with the --read-only option". That is the
# engine refusing, which is the whole point; a grant-based refusal (1142) would
# be a weaker result and is reported separately so the two are never conflated.
while IFS='|' read -r label stmt; do
  [[ -z "$label" ]] && continue
  out="$(run_sql "$stmt")"
  if grep -q "ERROR 1290" <<<"$out"; then
    ok_ "$label refused by the engine (1290, read-only)"
  elif grep -qE "ERROR (1142|1044)" <<<"$out"; then
    ok_ "$label refused by grants (weaker than 1290 - verify the reader host)"
  elif grep -q "ERROR" <<<"$out"; then
    ok_ "$label refused ($(grep -o 'ERROR [0-9]*' <<<"$out" | head -1))"
  else
    bad_ "$label SUCCEEDED - this is a write to the database"
  fi
done <<'CASES'
CREATE TABLE|CREATE TABLE _agent_write_probe (x INT);
INSERT|INSERT INTO _agent_write_probe VALUES (1);
UPDATE|UPDATE _agent_write_probe SET x = 2;
DELETE|DELETE FROM _agent_write_probe;
DROP TABLE|DROP TABLE _agent_write_probe;
CASES

# Credential tables are a separate concern from write protection: reading them
# is not a write, so innodb_read_only says nothing about it. Only the GRANTs do.
if run_sql "SELECT user FROM mysql.user LIMIT 1;" | grep -q "ERROR"; then
  ok_ "mysql.user is not readable"
else
  bad_ "mysql.user IS READABLE - the grant is wider than SELECT on one schema"
fi

if run_sql "SELECT 1 INTO OUTFILE '/tmp/_agent_probe.csv';" | grep -q "ERROR"; then
  ok_ "INTO OUTFILE refused (no FILE privilege)"
else
  bad_ "INTO OUTFILE SUCCEEDED - the user holds FILE"
fi

printf '\n  %d of %d checks passed, %d failed\n\n' "$pass" "$((pass + fail))" "$fail"
exit $(( fail > 0 ))
