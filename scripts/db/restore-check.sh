#!/bin/sh
# Restores a backup made by backup.sh into a TARGET database that is not production (a new Supabase project, a
# staging project, or a local one), then compares row counts with the backup's counts.txt. Prints counts only.
# Usage:  TARGET_URL='postgresql://...' sh scripts/db/restore-check.sh /safe/folder/classi-backup-<stamp>
# DATA_ONLY=1: the target already has the schema (all migrations applied): its public tables are emptied (rows the
# migrations insert, such as default settings, and the photo bucket) and data.sql is loaded. Never on production (checked above).
set -eu
. "$(dirname "$0")/guard.sh"
DIR="${1:?usage: TARGET_URL=... sh scripts/db/restore-check.sh <backup folder>}"
: "${TARGET_URL:?set TARGET_URL (not printed)}"
is_prod "$TARGET_URL" && { echo "refusing: TARGET_URL is the production project"; exit 2; }
need psql
( cd "$DIR" && sha256sum -c --quiet SHA256SUMS ) || { echo "checksums do not match: the backup is damaged"; exit 1; }
echo "restoring into $(host_of "$TARGET_URL") ..."
set -- --single-transaction -v ON_ERROR_STOP=1 -q
if [ "${DATA_ONLY:-}" = 1 ]; then
  psql "$TARGET_URL" "$@" -c "do \$\$ declare t text; begin
      select string_agg(format('%I.%I', schemaname, tablename), ', ') into t from pg_tables
       where schemaname = 'public' or (schemaname = 'storage' and tablename in ('buckets', 'objects'));
      if t is not null then execute 'truncate ' || t || ' cascade'; end if; end \$\$;" \
    -c 'set session_replication_role = replica' -f "$DIR/data.sql" >/dev/null
else
  [ -f "$DIR/roles.sql" ] && set -- "$@" -f "$DIR/roles.sql"
  psql "$TARGET_URL" "$@" -f "$DIR/schema.sql" -c 'set session_replication_role = replica' -f "$DIR/data.sql" >/dev/null
fi
psql "$TARGET_URL" -At -c "select string_agg(format('select %L || ''|'' || count(*) from %I.%I', n.nspname || '.' || c.relname, n.nspname, c.relname), ' union all ' order by n.nspname, c.relname)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind = 'r' and n.nspname in ('public', 'auth') and c.relname not like 'schema_migrations%'" > /tmp/classi-restore-q.sql
psql "$TARGET_URL" -At -f /tmp/classi-restore-q.sql | sort > /tmp/classi-restore-counts.txt; rm -f /tmp/classi-restore-q.sql
if diff -u "$DIR/counts.txt" /tmp/classi-restore-counts.txt > /tmp/classi-restore-diff.txt; then
  echo "PASS: $(wc -l < "$DIR/counts.txt") tables, every row count matches the backup"
else
  echo "FAIL: row counts differ (table|count):"; grep '^[-+][a-z]' /tmp/classi-restore-diff.txt; exit 1
fi
rm -f /tmp/classi-restore-counts.txt /tmp/classi-restore-diff.txt
