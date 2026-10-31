#!/bin/sh
# Run every *_test.sql suite, each in its own fresh database, and compare with the expected results.
#  - Suites print their results; lines with "ERROR" are refusals the suite expects (e.g. "teacher books own offer").
#    The expected number per suite is in expected_errors.txt; a different number fails the run.
#  - Any line containing "FAIL:" fails the run (assertion suites such as security_test print PASS:/FAIL:).
# Output of each suite: $OUT/<suite>.out   Usage: sh supabase/tests/run_all.sh [suite ...]
T="$(cd "$(dirname "$0")" && pwd)"
OUT=${OUT:-/tmp/classi-test-results}; mkdir -p "$OUT"
SUITES=${*:-$(cd "$T" && ls *_test.sql | sed 's/\.sql$//')}
# Roles are cluster-wide: create them once here, so parallel database builds never race to create them.
psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q -c "do \$\$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end \$\$;" >/dev/null
echo "$SUITES" | tr ' ' '\n' | grep . | xargs -P ${JOBS:-4} -I{} sh -c "DB=ct_{} sh '$T/run.sh' {} > '$OUT/{}.out' 2>&1; echo \$? > '$OUT/{}.rc'"
fail=0
printf '%-16s %3s %8s %8s %6s  %s\n' suite rc errors expected fails result
for s in $SUITES; do
  rc=$(cat "$OUT/$s.rc"); e=$(grep -c "ERROR" "$OUT/$s.out"); f=$(grep -c "FAIL:" "$OUT/$s.out")
  x=$(awk -v s="$s" '$1==s {print $2}' "$T/expected_errors.txt"); x=${x:-0}
  if [ "$rc" = 0 ] && [ "$e" = "$x" ] && [ "$f" = 0 ]; then r=ok; else r=FAILED; fail=1; fi
  printf '%-16s %3s %8s %8s %6s  %s\n' "$s" "$rc" "$e" "$x" "$f" "$r"
done
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q"
for s in $SUITES; do $P -c "drop database if exists ct_$s" >/dev/null 2>&1; done
exit $fail
