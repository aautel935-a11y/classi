#!/bin/sh
# Forward drill: build the schema with every migration, apply migration file(s) that are prepared but not yet in
# supabase/migrations (supabase/pending/...), then optionally down file(s), then run suites.
# Usage: sh supabase/tests/forward_drill.sh <pending.sql[,more.sql]> <suite> [suite ...]
#        DOWN=<down.sql[,…]> sh supabase/tests/forward_drill.sh …   (apply the down files after the pending ones)
T="$(cd "$(dirname "$0")" && pwd)"; UP="$1"; shift
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q"
fail=0
for s in "$@"; do
  $P -c "drop database if exists ct_fwd" -c "create database ct_fwd" >/dev/null
  D="env PGOPTIONS=-cclient_min_messages=warning $P -d ct_fwd -v ON_ERROR_STOP=1"
  $D -f "$T/supabase_stub.sql" >/dev/null
  for f in "$T"/../migrations/*.sql; do $D -f "$f" >/dev/null; done
  $D -f "$T/../seed.sql" >/dev/null; $D -f "$T/grants.sql" >/dev/null
  for u in $(echo "$UP" | tr ',' ' '); do $D -f "$u" >/dev/null || { echo "FAIL: $u did not apply"; exit 1; }; done
  for d in $(echo "${DOWN:-}" | tr ',' ' '); do $D -f "$d" >/dev/null || { echo "FAIL: down file $d did not apply"; exit 1; }; done
  $P -d ct_fwd -f "$T/$s.sql" > /tmp/fwd_$s.out 2>&1
  e=$(grep -c ERROR /tmp/fwd_$s.out); f=$(grep -c "FAIL:" /tmp/fwd_$s.out); x=$(awk -v s=$s '$1==s{print $2}' "$T/expected_errors.txt")
  if [ "$e" = "${x:-0}" ] && [ "$f" = 0 ]; then echo "PASS: with ${UP##*/}${DOWN:+ then ${DOWN##*/}}, $s ($e expected refusals, $(grep -c 'PASS:' /tmp/fwd_$s.out) checks)"; else echo "FAIL: with ${UP##*/}, $s errors=$e expected=$x fails=$f"; grep "FAIL:" /tmp/fwd_$s.out | head -5; fail=1; fi
done
$P -c "drop database if exists ct_fwd" >/dev/null
exit $fail
