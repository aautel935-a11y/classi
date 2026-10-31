#!/bin/sh
# Restores a backup made by backup.sh into a TARGET database that is not production (a new Supabase project, a
# staging project, or a local one), then compares row counts with the backup's counts.txt. Prints counts only.
# Usage:  TARGET_URL='postgresql://...' sh scripts/db/restore-check.sh /safe/folder/classi-backup-<stamp>
# DATA_ONLY=1: the target already has the schema (all migrations applied): its public tables are emptied (rows the
# migrations insert, such as default settings) and data.sql is loaded. Never on production (checked below).
set -eu
. "$(dirname "$0")/guard.sh"
DIR="${1:?usage: TARGET_URL=... sh scripts/db/restore-check.sh <backup folder>}"
: "${TARGET_URL:?set TARGET_URL (not printed)}"
check_url "$TARGET_URL"
is_prod "$TARGET_URL" && { echo "refusing: TARGET_URL is the production project"; exit 2; }
need psql
( cd "$DIR" && sha256sum -c --quiet SHA256SUMS ) || { echo "FAIL: checksums do not match: the backup is damaged"; exit 1; }
# A target that already holds accounts is treated as live data: refuse (a restore replaces or empties tables).
users=$(psql "$TARGET_URL" -At -v ON_ERROR_STOP=1 -c "select count(*) from auth.users")
if [ "$users" -gt 20 ] && [ "${FORCE_NONEMPTY:-}" != 1 ]; then echo "refusing: the target already has $users accounts"; exit 2; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "restoring into $(host_of "$TARGET_URL") ..."
if [ "${DATA_ONLY:-}" = 1 ]; then
  psql "$TARGET_URL" --single-transaction -v ON_ERROR_STOP=1 -q -c "do \$\$ declare t text; begin
      select string_agg(format('%I.%I', schemaname, tablename), ', ') into t from pg_tables where schemaname = 'public';
      if t is not null then execute 'truncate ' || t || ' cascade'; end if; end \$\$;" \
    -c 'set session_replication_role = replica' -f "$DIR/data.sql" >/dev/null
else
  set -- --single-transaction -v ON_ERROR_STOP=1 -q
  [ -f "$DIR/roles.sql" ] && set -- "$@" -f "$DIR/roles.sql"
  psql "$TARGET_URL" "$@" -f "$DIR/schema.sql" -c 'set session_replication_role = replica' -f "$DIR/data.sql" >/dev/null
fi
# Count the same tables the backup holds.
awk -F'|' '{split($1, a, "."); printf "%sselect %s || chr(124) || count(*) from %s.%s\n", (NR > 1 ? "union all " : ""), "\x27" $1 "\x27", "\"" a[1] "\"", "\"" a[2] "\""}' "$DIR/counts.txt" > "$TMP/q.sql"
psql "$TARGET_URL" -At -v ON_ERROR_STOP=1 -f "$TMP/q.sql" | sort > "$TMP/counts.txt"
if diff -u "$DIR/counts.txt" "$TMP/counts.txt" > "$TMP/diff.txt"; then
  echo "PASS: $(wc -l < "$DIR/counts.txt") tables, every row count matches the backup"
else
  echo "FAIL: row counts differ (table|count):"; grep '^[-+][a-z]' "$TMP/diff.txt"; exit 1
fi
