#!/bin/sh
# Production (classi, rfxhqcagdsuhkjzwbawx) was checked READ-ONLY on 20/11/2026 with scripts/production/fingerprint.sql:
# its public schema equals the 25 migrations up to 20261027020000_support (main). This test rebuilds that schema
# locally from the same files and checks it still gives the recorded fingerprint, so any later edit of an applied
# migration file, or of the fingerprint query, fails CI before production guard files are generated from it.
# Never connects to a hosted database.   Usage: sh supabase/tests/production_fingerprint_test.sh
set -u
T="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$T/../.." && pwd)"
LAST=20261027020000
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q"
DB=ct_prodfp
$P -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
D="env PGOPTIONS=-cclient_min_messages=warning $P -d $DB -v ON_ERROR_STOP=1"
$D -f "$T/supabase_stub.sql" >/dev/null
n=0
for f in "$REPO"/supabase/migrations/*.sql; do
  v=$(basename "$f" | cut -d_ -f1); [ "$v" -le "$LAST" ] || continue
  $D -f "$f" >/dev/null || { echo "FAIL: $(basename "$f") does not apply"; exit 1; }; n=$((n + 1))
done
$D -f "$T/grants.sql" >/dev/null
got=$($P -d $DB -At -f "$REPO/scripts/production/fingerprint.sql" | grep '|')
$P -c "drop database if exists $DB" >/dev/null 2>&1
fail=0
[ "$n" = 25 ] && echo "PASS: 25 migrations up to $LAST (production's set)" || { echo "FAIL: $n migrations up to $LAST, production has 25"; fail=1; }
if [ "$got" = "$(cat "$REPO/scripts/production/expected_$LAST.txt")" ]; then
  echo "PASS: rebuilt schema = the production fingerprint recorded on 20/11 (functions, columns, policies, triggers, RLS)"
else
  echo "FAIL: rebuilt schema differs from the recorded production fingerprint:"; echo "$got" | diff "$REPO/scripts/production/expected_$LAST.txt" - ; fail=1
fi
exit $fail
