#!/bin/sh
# Applies NEW migrations (supabase/migrations) to the already-prepared STAGING database, and nothing else:
# no seed, no demo or test data, no re-initialisation. Running it again with nothing new changes nothing.
# Used by .github/workflows/staging-migrate.yml (manual, owner approval). Prints no secrets.
#
# Four identity checks before any change (any failure stops here):
#   1. the link: present, a postgresql:// URL, contains the classi-staging ref, never the production ref
#   2. the database: its cluster id is classi-staging's (read through the Supabase connector)
#   3. the marker: app_secrets deploy_env = 'staging' (only the staging setup creates it)
#   4. an already-prepared database: migration history present, staging accounts only (never an empty or foreign one)
#      and the dispatcher never pointing at the production site
#
# CI test mode (MIGRATE_TEST=1, only with CI=true and a 127.0.0.1 database): checks 1-2 use the local stack's values,
# so the script can be exercised end to end in CI without ever reaching the real staging project.
set -eu
. "$(dirname "$0")/../db/guard.sh"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

STAGING_REF="nfipmylyahhogykikuqo"
STAGING_SYSID="7702070854497379551"

: "${STAGING_DB_URL:=}"
[ -n "$STAGING_DB_URL" ] || { echo "refusing: STAGING_DB_URL is not set"; exit 2; }
check_url "$STAGING_DB_URL"
is_prod "$STAGING_DB_URL" && { echo "refusing: this is the production project"; exit 2; }

if [ "${MIGRATE_TEST:-}" = 1 ]; then
  [ "${CI:-}" = true ] || { echo "refusing: test mode is for CI only"; exit 2; }
  case "$(host_of "$STAGING_DB_URL")" in 127.0.0.1|localhost) ;; *) echo "refusing: test mode needs the local stack"; exit 2;; esac
  STAGING_SYSID="$(psql "$STAGING_DB_URL" -Atc "select system_identifier from pg_control_system()")"
else
  # 1. the link names classi-staging (Session pooler user postgres.<ref>, or the direct host db.<ref>.supabase.co)
  case "$STAGING_DB_URL" in *"$STAGING_REF"*) ;; *) echo "refusing: STAGING_DB_URL is not classi-staging ($STAGING_REF)"; exit 2;; esac
fi
need psql
Q() { psql "$STAGING_DB_URL" -v ON_ERROR_STOP=1 -At "$@"; }
echo "database host: $(host_of "$STAGING_DB_URL")"

# 2. identity of the database itself
sysid="$(Q -c "select system_identifier from pg_control_system()")"
[ "$sysid" = "$STAGING_SYSID" ] || { echo "refusing: connected, but this is not the classi-staging database"; exit 2; }
# 3. the staging marker
[ "$(Q -c "select count(*) from public.app_secrets where key = 'deploy_env' and value = 'staging'")" = 1 ] \
  || { echo "refusing: the database is not marked staging"; exit 2; }
# 4. an already-prepared staging database (this script never initialises one), no production dispatcher
applied_before="$(Q -c "select count(*) from supabase_migrations.schema_migrations")"
# prepared = the full history up to phase 4 is recorded (new migrations come after it)
[ "$(Q -c "select count(*) from supabase_migrations.schema_migrations where version in ('20261024000000', '20261101000000')")" = 2 ] && [ "$applied_before" -ge 29 ] \
  || { echo "refusing: migration history missing or short ($applied_before): this script only updates a prepared staging database"; exit 2; }
[ "$(Q -c "select count(*) from public.app_secrets where key = 'dispatch_url' and value ilike '%classi.click%'")" = 0 ] \
  || { echo "refusing: the dispatcher points at the production site"; exit 2; }
[ "$(Q -c "select count(*) from auth.users")" -le "${MAX_ACCOUNTS:-50}" ] \
  || { echo "refusing: more accounts than a staging database should hold"; exit 2; }

# Row counts of the main tables before (to prove nothing is duplicated or reset)
counts() { Q -c "select string_agg(t || '=' || n, ' ' order by t) from (
  select 'teachers' t, count(*) n from public.teachers union all select 'institutes', count(*) from public.institutes
  union all select 'offerings', count(*) from public.offerings union all select 'bookings', count(*) from public.bookings
  union all select 'profiles', count(*) from public.profiles union all select 'accounts', count(*) from auth.users) x"; }
before="$(counts)"

# Pending migrations, then apply them (never the seed)
pending=""
for f in "$REPO"/supabase/migrations/*.sql; do
  v=$(basename "$f" | cut -d_ -f1)
  [ "$(Q -c "select count(*) from supabase_migrations.schema_migrations where version = '$v'")" = 1 ] || pending="$pending $(basename "$f")"
done
# Migrations that have their own guarded file in supabase/staging/ (apply_<name>.sql) are applied ONLY with that file,
# one at a time, after the owner's approval: never here, and never together (for example the private-photo steps A
# and B, which need the new app code deployed in between). Refuse before changing anything.
manual=""
for f in $pending; do [ -f "$REPO/supabase/staging/apply_${f%.sql}.sql" ] && manual="$manual $f"; done
[ -z "$manual" ] || { echo "refusing: these pending migrations are applied only with their own guarded staging file (supabase/staging/apply_<name>.sql), one at a time:$manual"; exit 2; }
if [ -z "$pending" ]; then
  echo "no new migrations: nothing to apply ($applied_before applied)"
else
  echo "new migrations:$pending"
  if command -v supabase >/dev/null 2>&1; then
    (cd "$REPO" && supabase db push --db-url "$STAGING_DB_URL")       # no --include-seed
  else
    for f in $pending; do
      v=$(echo "$f" | cut -d_ -f1)
      echo "  applying $f"
      psql "$STAGING_DB_URL" -v ON_ERROR_STOP=1 -q --single-transaction -f "$REPO/supabase/migrations/$f" \
        -c "insert into supabase_migrations.schema_migrations (version, name) values ('$v', '$(basename "$f" .sql)')"
    done
  fi
fi

after="$(counts)"
echo "migrations applied: $(Q -c "select count(*) from supabase_migrations.schema_migrations") (was $applied_before), last $(Q -c "select max(version) from supabase_migrations.schema_migrations")"
echo "scheduled jobs: $(Q -c "select count(*) from cron.job where jobname like 'classi-%'")"
echo "rows before: $before"
echo "rows after:  $after"
# A migration may add reference rows, but the demo and account tables must never grow or shrink here.
[ "$before" = "$after" ] || { echo "WARNING: row counts changed during the migration (check the migration)"; exit 3; }
echo "done: no seed, no data loaded, counts unchanged"
