#!/bin/sh
# Backup of a Classi database (production included: this only READS). Produces, in a folder OUTSIDE the repository:
#   roles.sql (CLI only), schema.sql, data.sql   restorable into a new Supabase project
#   counts.txt   rows per table as stored in data.sql (no content): lets a restore be checked without looking at data
#   SHA256SUMS
# Usage:  DB_URL='postgresql://postgres.<ref>:<password>@<host>:5432/postgres' sh scripts/db/backup.sh /safe/folder
# The URL comes from Supabase -> Project Settings -> Database -> Connection string (session pooler). Never commit it.
set -eu
. "$(dirname "$0")/guard.sh"
OUT="${1:?usage: DB_URL=... sh scripts/db/backup.sh <folder outside the repo>}"
: "${DB_URL:?set DB_URL (not printed)}"
check_url "$DB_URL"
REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
mkdir -p "$OUT"; OUTABS="$(cd "$OUT" && pwd -P)"
case "$OUTABS/" in "$REPO"/*) echo "refusing: the backup must not be inside the repository"; exit 2;; esac
need psql
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; DIR="$OUTABS/classi-backup-$STAMP"; mkdir -m 700 "$DIR"
echo "backup of $(host_of "$DB_URL") -> $DIR"
if command -v supabase >/dev/null 2>&1; then
  supabase db dump --db-url "$DB_URL" -f "$DIR/roles.sql" --role-only
  supabase db dump --db-url "$DB_URL" -f "$DIR/schema.sql"
  # data of the app and of the accounts; photo files are copied separately (BACKUP-RESTORE.md), storage tables are
  # Supabase's own and cannot be written back by the postgres role
  supabase db dump --db-url "$DB_URL" -f "$DIR/data.sql" --use-copy --data-only --schema public,auth
else
  need pg_dump
  echo "(Supabase CLI not found: pg_dump of the app and auth schemas)"
  pg_dump "$DB_URL" --schema-only --no-owner --schema=public --schema=app_private -f "$DIR/schema.raw"
  sed 's/^CREATE SCHEMA public;/CREATE SCHEMA IF NOT EXISTS public;/' "$DIR/schema.raw" > "$DIR/schema.sql"; rm -f "$DIR/schema.raw"
  pg_dump "$DB_URL" --data-only --no-owner --schema=public --schema=auth --exclude-table='auth.schema_migrations' -f "$DIR/data.sql"
fi
# Every file must exist and be non-empty; the dump must hold the app's tables.
for f in schema.sql data.sql; do [ -s "$DIR/$f" ] || { echo "FAIL: $f is missing or empty"; exit 1; }; done
copy_counts "$DIR/data.sql" > "$DIR/counts.txt"
grep -q '^public\.profiles|' "$DIR/counts.txt" || { echo "FAIL: the dump holds no public.profiles table"; exit 1; }
( cd "$DIR" && sha256sum *.sql counts.txt > SHA256SUMS )
chmod 600 "$DIR"/*
echo "done: $(wc -l < "$DIR/counts.txt") tables, $(awk -F'|' '{s+=$2} END {print s+0}' "$DIR/counts.txt") rows; files: $(ls "$DIR" | tr '\n' ' ')"
echo "Keep this folder off the laptop's synced folders, and delete it when no longer needed (it holds personal data)."
