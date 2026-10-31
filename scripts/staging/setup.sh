#!/bin/sh
# Prepares a STAGING Supabase project for Classi: every migration in order, synthetic seed data, the scheduled jobs,
# photo storage, and the server-to-server settings pointing at the STAGING app (never at production).
# It refuses the production project. It prints no secrets.
# Usage:
#   STAGING_DB_URL='postgresql://postgres.<staging ref>:<password>@<host>:5432/postgres' \
#   STAGING_APP_URL='https://<staging app>.vercel.app' sh scripts/staging/setup.sh
set -eu
. "$(dirname "$0")/../db/guard.sh"
: "${STAGING_DB_URL:?set STAGING_DB_URL (not printed)}"
: "${STAGING_APP_URL:?set STAGING_APP_URL, e.g. https://classi-staging.vercel.app}"
is_prod "$STAGING_DB_URL" && { echo "refusing: this is the production project"; exit 2; }
case "$STAGING_APP_URL" in *classi.click*) echo "refusing: STAGING_APP_URL is the production site"; exit 2;; https://*) ;; *) echo "STAGING_APP_URL must start with https://"; exit 2;; esac
need psql
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
P="psql $STAGING_DB_URL -v ON_ERROR_STOP=1 -q"
echo "staging database: $(host_of "$STAGING_DB_URL")"

# 1. Refuse a database that already holds real-looking data (more than the seed's few accounts).
users=$(psql "$STAGING_DB_URL" -At -c "select count(*) from auth.users" 2>/dev/null || echo 0)
if [ "${users:-0}" -gt 20 ] && [ "${FORCE_NONEMPTY:-}" != 1 ]; then echo "refusing: $users accounts already exist (staging must start empty)"; exit 2; fi

# 2. Migrations, in file-name order, recorded so the Supabase CLI sees them as applied.
if command -v supabase >/dev/null 2>&1; then
  (cd "$REPO" && supabase db push --db-url "$STAGING_DB_URL" --include-seed)
else
  $P -c "create schema if not exists supabase_migrations; create table if not exists supabase_migrations.schema_migrations (version text primary key, name text, statements text[])"
  fresh=$(psql "$STAGING_DB_URL" -At -c "select count(*) = 0 from supabase_migrations.schema_migrations")
  for f in "$REPO"/supabase/migrations/*.sql; do
    v=$(basename "$f" | cut -d_ -f1)
    if [ "$(psql "$STAGING_DB_URL" -At -c "select count(*) from supabase_migrations.schema_migrations where version = '$v'")" = 0 ]; then
      echo "  migration $(basename "$f")"
      $P --single-transaction -f "$f" -c "insert into supabase_migrations.schema_migrations (version, name) values ('$v', '$(basename "$f" .sql)')"
    fi
  done
  # synthetic seed only on a fresh database (it is not meant to run twice)
  [ "$fresh" = t ] && $P -f "$REPO/supabase/seed.sql"
fi

# 3. Scheduled jobs and photo storage (normally created by the migrations; re-applied idempotently).
$P -f "$REPO/scripts/db/cron-jobs.sql" >/dev/null
$P -f "$REPO/scripts/db/storage-setup.sql" 2>/dev/null

# 4. Server-to-server settings: the database calls the STAGING app; a fresh random secret (never printed).
$P -c "insert into public.app_secrets (key, value) values
         ('dispatch_url', '$STAGING_APP_URL/api/push/dispatch'),
         ('dispatch_secret', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
       on conflict (key) do update set value = excluded.value"

# 5. Checks
psql "$STAGING_DB_URL" -At -c "select 'migrations applied: ' || count(*) from supabase_migrations.schema_migrations"
psql "$STAGING_DB_URL" -At -c "select 'dispatch_url points at production: ' || (value like '%classi.click%') from public.app_secrets where key = 'dispatch_url'"
psql "$STAGING_DB_URL" -At -c "select 'scheduled jobs: ' || count(*) from cron.job where jobname like 'classi-%'"
psql "$STAGING_DB_URL" -At -c "select 'accounts: ' || count(*) from auth.users"
echo "Next: Supabase dashboard of the STAGING project -> Auth settings (see docs/hardening/LAUNCH-CHECKLIST.md, section Staging)."
