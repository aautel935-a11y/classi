#!/bin/sh
# v3 rollback check (local databases only): a schema built WITHOUT the v3 migrations must be identical — every public
# function (body, settings, anon/authenticated EXECUTE), table count and column list — to a schema built WITH them and
# then rolled back with the v3 down files (newest first). Prints PASS:/FAIL:. Usage: sh supabase/tests/v3_rollback_test.sh
T="$(cd "$(dirname "$0")" && pwd)"; S="$T/.."
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q"
fp() { $P -d "$1" -Atc "select md5(string_agg(format('%s(%s)|%s|%s|%s|%s', p.proname, pg_get_function_identity_arguments(p.oid), md5(p.prosrc),
  has_function_privilege('anon',p.oid,'execute'), has_function_privilege('authenticated',p.oid,'execute'), coalesce(array_to_string(p.proconfig,','),'-')),
  E'\n' order by p.proname, p.oid)) || ':' || (select count(*) from pg_tables where schemaname='public') || ':' ||
  (select md5(string_agg(table_name||'.'||column_name, ',' order by table_name, column_name)) from information_schema.columns where table_schema='public')
  from pg_proc p where p.pronamespace='public'::regnamespace"; }
build() { # <db> <with v3: yes|no>
  $P -c "drop database if exists $1" -c "create database $1" >/dev/null 2>&1
  D="env PGOPTIONS=-cclient_min_messages=warning $P -d $1 -v ON_ERROR_STOP=1"
  $D -f "$T/supabase_stub.sql" >/dev/null || return 1
  for f in "$S"/migrations/*.sql; do
    case "$(basename "$f")" in *_v3_*) [ "$2" = yes ] || continue;; esac
    $D -f "$f" >/dev/null || return 1
  done
}
fail=0
build ct_v3_before no || { echo "FAIL: could not build the pre-v3 schema"; exit 1; }
build ct_v3_after yes || { echo "FAIL: could not build the v3 schema"; exit 1; }
DOWNS=$(ls "$S"/rollback/*_v3_*.down.sql | sort -r)
for d in $DOWNS; do
  env PGOPTIONS=-cclient_min_messages=warning $P -d ct_v3_after -v ON_ERROR_STOP=1 -f "$d" >/dev/null || { echo "FAIL: $(basename "$d") did not apply"; fail=1; }
done
a=$(fp ct_v3_before); b=$(fp ct_v3_after)
if [ "$fail" = 0 ] && [ -n "$a" ] && [ "$a" = "$b" ]; then echo "PASS: the v3 down files restore the exact pre-v3 schema ($(echo $DOWNS | wc -w) files)"
else echo "FAIL: schema after rollback differs from before v3"; fail=1; fi
$P -c "drop database if exists ct_v3_before" -c "drop database if exists ct_v3_after" >/dev/null 2>&1
exit $fail
