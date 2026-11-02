#!/bin/sh
# Tests scripts/staging/migrate.sh on a throwaway LOCAL database that looks like classi-staging (all migrations with
# their history, the staging marker, the staging data). Never touches a hosted database.
# Usage: sh supabase/tests/staging_migrate_test.sh   (local Postgres, or CI's service via PGSOCK/PGPORT/PGPASSWORD)
set -u
T="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$T/../.." && pwd)"
SOCK=${PGSOCK:-/var/tmp/pgc}; PORT=${PGPORT:-54329}; DB=ct_stgmig
P="psql -h $SOCK -p $PORT -U postgres -q"
case "$SOCK" in /*) URL="postgresql://postgres@localhost:$PORT/$DB?host=$SOCK";; *) URL="postgresql://postgres:${PGPASSWORD:-postgres}@$SOCK:$PORT/$DB";; esac
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; fail=$((fail + 1)); }
run() { env -u PGHOST -u PGDATABASE -u PGUSER "$@" sh "$REPO/scripts/staging/migrate.sh" > /tmp/stgmig.out 2>&1; }

# a database like classi-staging: every migration recorded, marker, dispatcher, staging data
printf 'select 1;\n' > "$T/zz_stgmig_noop.sql"
DB=$DB sh "$T/run.sh" zz_stgmig_noop >/dev/null 2>&1; rm -f "$T/zz_stgmig_noop.sql"
D="$P -d $DB -v ON_ERROR_STOP=1"
$D -c "create schema if not exists supabase_migrations; create table if not exists supabase_migrations.schema_migrations (version text primary key, name text, statements text[])" \
   -c "do \$\$ begin if to_regclass('cron.job') is null then create schema if not exists cron; create table cron.job (jobname text); end if; end \$\$"
for f in "$REPO"/supabase/migrations/*.sql; do v=$(basename "$f" | cut -d_ -f1); $D -c "insert into supabase_migrations.schema_migrations (version, name) values ('$v', '$(basename "$f" .sql)') on conflict do nothing"; done
$D -c "insert into public.app_secrets (key, value) values ('deploy_env', 'staging'), ('dispatch_url', 'https://classi-staging.invalid/api/push/dispatch') on conflict (key) do update set value = excluded.value"
$D -f "$REPO/supabase/staging/staging_data.sql" >/dev/null 2>&1

# refusals
run STAGING_DB_URL= && ko "missing link refused" || { grep -q "not set" /tmp/stgmig.out && ok "missing link refused" || ko "missing link refused ($(tail -1 /tmp/stgmig.out))"; }
run STAGING_DB_URL="postgresql://postgres.rfxhqcagdsuhkjzwbawx:x@aws-1-eu-central-1.pooler.supabase.com:5432/postgres" && ko "production link refused" || { grep -q "production" /tmp/stgmig.out && ok "production link refused" || ko "production link refused ($(tail -1 /tmp/stgmig.out))"; }
run STAGING_DB_URL="postgresql://postgres.someotherproject:x@aws-1-eu-central-1.pooler.supabase.com:5432/postgres" && ko "other project refused" || { grep -q "not classi-staging" /tmp/stgmig.out && ok "link of another project refused" || ko "other project refused ($(tail -1 /tmp/stgmig.out))"; }
run STAGING_DB_URL="$URL" && ko "local database without test mode refused" || { grep -q "not classi-staging" /tmp/stgmig.out && ok "a database whose link does not name classi-staging is refused" || ko "local db refused ($(tail -1 /tmp/stgmig.out))"; }
# a link that names classi-staging but reaches another database: stopped by the cluster id (check 2)
case "$URL" in *\?*) NAMED="$URL&application_name=nfipmylyahhogykikuqo";; *) NAMED="$URL?application_name=nfipmylyahhogykikuqo";; esac
run STAGING_DB_URL="$NAMED" && ko "foreign database behind a staging-looking link refused" || { grep -q "not the classi-staging database" /tmp/stgmig.out && ok "a staging-looking link to another database is stopped by the cluster id" || ko "cluster id ($(tail -1 /tmp/stgmig.out))"; }
run STAGING_DB_URL="$URL" MIGRATE_TEST=1 CI= && ko "test mode outside CI refused" || { grep -q "CI only" /tmp/stgmig.out && ok "test mode outside CI refused" || ko "test mode outside CI ($(tail -1 /tmp/stgmig.out))"; }

# the happy path: nothing new, nothing changes; run twice
run STAGING_DB_URL="$URL" MIGRATE_TEST=1 CI=true && grep -q "no new migrations" /tmp/stgmig.out && grep -q "counts unchanged" /tmp/stgmig.out \
  && ok "nothing new: nothing applied, counts unchanged" || ko "nothing new ($(tail -3 /tmp/stgmig.out | tr '\n' ' '))"
before=$($D -Atc "select count(*) from public.teachers")
# one migration pending (the latest; its functions are re-created in place): applied once, counts unchanged
last=$(ls "$REPO"/supabase/migrations/*.sql | tail -1); lv=$(basename "$last" | cut -d_ -f1)
$D -c "delete from supabase_migrations.schema_migrations where version = '$lv'"
run STAGING_DB_URL="$URL" MIGRATE_TEST=1 CI=true && grep -q "new migrations: $(basename "$last")" /tmp/stgmig.out && grep -q "counts unchanged" /tmp/stgmig.out \
  && [ "$($D -Atc "select count(*) from supabase_migrations.schema_migrations where version = '$lv'")" = 1 ] \
  && ok "a pending migration is applied once and recorded" || ko "pending migration ($(tail -3 /tmp/stgmig.out | tr '\n' ' '))"
run STAGING_DB_URL="$URL" MIGRATE_TEST=1 CI=true && grep -q "no new migrations" /tmp/stgmig.out && ok "running again applies nothing" || ko "rerun ($(tail -1 /tmp/stgmig.out))"
[ "$($D -Atc "select count(*) from public.teachers")" = "$before" ] && [ "$($D -Atc "select count(*) from auth.users")" = 5 ] \
  && ok "no seed or demo data loaded (teachers and accounts unchanged)" || ko "data changed"

# refusals on the database itself
$D -c "update public.app_secrets set value = 'https://classi.click/api/push/dispatch' where key = 'dispatch_url'"
run STAGING_DB_URL="$URL" MIGRATE_TEST=1 CI=true && ko "production dispatcher refused" || { grep -q "production site" /tmp/stgmig.out && ok "a database whose dispatcher is the production site is refused" || ko "dispatcher ($(tail -1 /tmp/stgmig.out))"; }
$D -c "update public.app_secrets set value = 'https://classi-staging.invalid/api/push/dispatch' where key = 'dispatch_url'"
$D -c "delete from public.app_secrets where key = 'deploy_env'"
run STAGING_DB_URL="$URL" MIGRATE_TEST=1 CI=true && ko "unmarked database refused" || { grep -q "not marked staging" /tmp/stgmig.out && ok "a database without the staging marker is refused" || ko "marker ($(tail -1 /tmp/stgmig.out))"; }
$D -c "insert into public.app_secrets (key, value) values ('deploy_env', 'staging')"
$D -c "delete from supabase_migrations.schema_migrations"
run STAGING_DB_URL="$URL" MIGRATE_TEST=1 CI=true && ko "empty history refused" || { grep -q "only updates a prepared" /tmp/stgmig.out && ok "a database without migration history is refused (never initialised here)" || ko "history ($(tail -1 /tmp/stgmig.out))"; }

$P -c "drop database if exists $DB" >/dev/null 2>&1
echo "staging migrate: $pass passed, $fail failed"
[ "$fail" = 0 ]
