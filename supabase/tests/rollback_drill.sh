#!/bin/sh
# Rollback drill: build the schema with every migration, apply a down file, then run suites that do not
# depend on what was rolled back. Usage: sh supabase/tests/rollback_drill.sh <down.sql[,older-down.sql]> <suite> [suite ...]
# Several down files (comma-separated) are applied in the order given, newest phase first.
T="$(cd "$(dirname "$0")" && pwd)"; DOWN="$1"; shift
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q"
fail=0
for s in "$@"; do
  $P -c "drop database if exists ct_drill" -c "create database ct_drill" >/dev/null
  D="env PGOPTIONS=-cclient_min_messages=warning $P -d ct_drill -v ON_ERROR_STOP=1"
  $D -f "$T/supabase_stub.sql" >/dev/null
  for f in "$T"/../migrations/*.sql; do $D -f "$f" >/dev/null; done
  $D -f "$T/../seed.sql" >/dev/null; $D -f "$T/grants.sql" >/dev/null
  for d in $(echo "$DOWN" | tr ',' ' '); do $D -f "$d" >/dev/null || { echo "FAIL: down file $d did not apply"; exit 1; }; done
  $P -d ct_drill -f "$T/$s.sql" > /tmp/drill_$s.out 2>&1
  e=$(grep -c ERROR /tmp/drill_$s.out); f=$(grep -c "FAIL:" /tmp/drill_$s.out); x=$(awk -v s=$s '$1==s{print $2}' "$T/expected_errors.txt")
  if [ "$e" = "${x:-0}" ] && [ "$f" = 0 ]; then echo "PASS: after rollback, $s ($e expected refusals)"; else echo "FAIL: after rollback, $s errors=$e expected=$x fails=$f"; fail=1; fi
done
$P -c "drop database if exists ct_drill" >/dev/null
exit $fail
