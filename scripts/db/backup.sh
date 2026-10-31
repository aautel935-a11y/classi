#!/bin/sh
# Backup of a Classi database (production included: this only READS). Produces, in a folder OUTSIDE the repository:
#   roles.sql, schema.sql, data.sql   (Supabase CLI format, restorable into a new project)
#   counts.txt                        (row count per table: lets a restore be checked without looking at data)
#   SHA256SUMS
# Usage:  DB_URL='postgresql://postgres.<ref>:<password>@<host>:5432/postgres' sh scripts/db/backup.sh /safe/folder
# The URL comes from Supabase -> Project Settings -> Database -> Connection string (session pooler). Never commit it.
set -eu
. "$(dirname "$0")/guard.sh"
OUT="${1:?usage: DB_URL=... sh scripts/db/backup.sh <folder outside the repo>}"
: "${DB_URL:?set DB_URL (not printed)}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
case "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" in "$REPO"*) echo "refusing: the backup must not be inside the repository"; exit 2;; esac
need psql
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; DIR="$OUT/classi-backup-$STAMP"; mkdir -p "$DIR"; chmod 700 "$DIR"
echo "backup of $(host_of "$DB_URL") -> $DIR"
if command -v supabase >/dev/null 2>&1; then
  supabase db dump --db-url "$DB_URL" -f "$DIR/roles.sql" --role-only
  supabase db dump --db-url "$DB_URL" -f "$DIR/schema.sql"
  supabase db dump --db-url "$DB_URL" -f "$DIR/data.sql" --use-copy --data-only
else
  need pg_dump
  echo "(Supabase CLI not found: pg_dump of the app and auth schemas)"
  pg_dump "$DB_URL" --schema-only --no-owner --schema=public --schema=app_private | sed 's/^CREATE SCHEMA public;/CREATE SCHEMA IF NOT EXISTS public;/' > "$DIR/schema.sql"
  pg_dump "$DB_URL" --data-only --no-owner --schema=public --schema=auth --exclude-table='auth.schema_migrations' -f "$DIR/data.sql"
fi
# Row counts only (no content): the reference for the restore check.
psql "$DB_URL" -At -v ON_ERROR_STOP=1 -c "select string_agg(format('select %L || ''|'' || count(*) from %I.%I', n.nspname || '.' || c.relname, n.nspname, c.relname), ' union all ' order by n.nspname, c.relname)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind = 'r' and n.nspname in ('public', 'auth') and c.relname not like 'schema_migrations%'" > "$DIR/.q.sql"
psql "$DB_URL" -At -v ON_ERROR_STOP=1 -f "$DIR/.q.sql" | sort > "$DIR/counts.txt"; rm -f "$DIR/.q.sql"
( cd "$DIR" && sha256sum *.sql counts.txt > SHA256SUMS )
chmod 600 "$DIR"/*
echo "done: $(wc -l < "$DIR/counts.txt") tables counted; files: $(ls "$DIR" | tr '\n' ' ')"
echo "Keep this folder off the laptop's synced folders, and delete it when no longer needed (it holds personal data)."
