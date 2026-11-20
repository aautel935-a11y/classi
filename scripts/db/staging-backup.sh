#!/bin/sh
# Encrypted backup of classi-staging and a restore proof in one run (workflow "Staging backup"; CI runs the same
# script on synthetic local databases). It reuses backup.sh (the dump: schema.sql, data.sql, counts.txt, SHA256SUMS)
# and restore-check.sh (checksums, full restore, row counts) and only adds the checks, the encryption and the proof.
# It only READS the source: its own queries run in read-only transactions and pg_dump's transaction is read-only.
#
#   DB_URL           the source (never printed)
#   TARGET_URL       an EMPTY local restore target (scripts/db/scratch-db.sh): loopback or socket, never the source
#   AGE_RECIPIENTS   a file with the age PUBLIC keys that may open the stored copy (the owner's), one per line
#   EXPECT_CLUSTER   the source's system identifier (classi-staging: 7702070854497379551)
#   EXPECT_REF       text the source URL must contain (classi-staging: nfipmylyahhogykikuqo); unset = local source only
# Usage:  ... sh scripts/db/staging-backup.sh <output folder outside the repository>
# Output: classi-staging-<stamp>.tar.age (encrypted), .tar.age.sha256, .summary.txt (totals only, no data).
# Plaintext exists only in a private temporary folder deleted on exit. The restore proof opens the encrypted file with
# a one-time key that is deleted before the restore, so afterwards only the owner's private key opens it.
# Nothing printed contains data: database messages are shown without quoted values and without CONTEXT/DETAIL lines
# (the workflow logs of a public repository are public).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd -P)"
. "$HERE/guard.sh"
OUT="${1:?usage: sh scripts/db/staging-backup.sh <output folder outside the repository>}"
: "${DB_URL:?set DB_URL (not printed)}"
: "${TARGET_URL:?set TARGET_URL (not printed)}"
: "${AGE_RECIPIENTS:?set AGE_RECIPIENTS (a file of age public keys)}"
: "${EXPECT_CLUSTER:?set EXPECT_CLUSTER}"
need psql; need age; need age-keygen; need tar; need sha256sum
refuse() { echo "refusing: $*"; exit 2; }
fail() { echo "FAIL: $*"; exit 1; }
# database messages without values: no quoted text, no CONTEXT/DETAIL/HINT/LINE lines (they can quote rows)
scrub() { grep -v -E '^(CONTEXT|DETAIL|HINT|LINE|QUERY)|^[[:space:]]' "$1" | sed -E "s/'[^']*'/'…'/g; s/\"[^\"]*\"/\"…\"/g; s/\([^)]*\)=\([^)]*\)/(…)=(…)/g" | tail -8; }
local_url() { case "$1" in *@127.0.0.1:*|*@localhost:*|*@\[::1\]:*|*@/*\?host=/*|*@/*\&host=/*) return 0;; *) return 1;; esac; }

check_url "$DB_URL"; check_url "$TARGET_URL"
is_prod "$DB_URL" && refuse "DB_URL is the production project"
is_prod "$TARGET_URL" && refuse "TARGET_URL is the production project"
[ "$DB_URL" != "$TARGET_URL" ] || refuse "the restore target is the source"
local_url "$TARGET_URL" || refuse "TARGET_URL must be a local database (loopback or socket)"
if [ -n "${EXPECT_REF:-}" ]; then
  case "$DB_URL" in *"$EXPECT_REF"*) ;; *) refuse "DB_URL is not the expected project";; esac
else
  local_url "$DB_URL" || refuse "without EXPECT_REF only a local source is accepted"
fi
[ -s "$AGE_RECIPIENTS" ] || refuse "AGE_RECIPIENTS is empty"
grep -qi 'AGE-SECRET-KEY' "$AGE_RECIPIENTS" && refuse "AGE_RECIPIENTS holds a PRIVATE key: give only public keys (age1...)"
keys=$(grep -c '^age1[0-9a-z]\{58\}$' "$AGE_RECIPIENTS" || true)
other=$(grep -v -e '^[[:space:]]*$' -e '^#' -e '^age1[0-9a-z]\{58\}$' "$AGE_RECIPIENTS" | wc -l)
[ "$keys" -ge 1 ] && [ "$other" = 0 ] || refuse "AGE_RECIPIENTS: one age public key (age1...) per line, nothing else"
REPO="$(cd "$HERE/../.." && pwd -P)"
mkdir -p "$OUT"; OUTABS="$(cd "$OUT" && pwd -P)"
case "$OUTABS/" in "$REPO"/*) refuse "the output folder must be outside the repository";; esac

umask 077
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT INT TERM
ro() { psql "$1" -X -q -At -v ON_ERROR_STOP=1 -c 'begin transaction read only' -c "$2" -c 'commit' 2>"$WORK/ro.err" || { scrub "$WORK/ro.err"; return 1; }; }

# 1. the source is the expected database; the target is empty
cluster=$(ro "$DB_URL" "select system_identifier from pg_control_system()") || fail "cannot read the source"
[ "$cluster" = "$EXPECT_CLUSTER" ] || refuse "the source cluster is not the expected one"
marker=$(ro "$DB_URL" "select coalesce((select value from public.app_secrets where key = 'deploy_env'), '')") || fail "cannot read the staging marker"
[ "$marker" = staging ] || refuse "the source has no staging marker"
newest() { ro "$DB_URL" "select coalesce(max(version), '-') from supabase_migrations.schema_migrations"; }
m1=$(newest) || fail "cannot read the recorded migrations"
tables=$(ro "$TARGET_URL" "select count(*) from pg_tables where schemaname = 'public'") || fail "cannot reach the restore target"
[ "$tables" = 0 ] || refuse "the restore target is not empty ($tables public tables)"
echo "source: expected cluster, staging marker, newest migration $m1; restore target: empty"

# 2. the dump (backup.sh: one pg_dump snapshot for all the data)
if ! sh "$HERE/backup.sh" "$WORK/plain" > "$WORK/backup.log" 2>&1; then scrub "$WORK/backup.log"; fail "the dump did not complete"; fi
grep -E '^(done:|\(Supabase CLI)' "$WORK/backup.log" || true
B=$(ls -d "$WORK"/plain/classi-backup-* | tail -1)
m2=$(newest) || fail "cannot read the recorded migrations"
[ "$m1" = "$m2" ] || fail "a migration was recorded during the dump ($m1 -> $m2): run again"

# 3. encrypt to the owner's keys and to a one-time key (for the proof only)
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; NAME="classi-staging-$STAMP"; F="$OUTABS/$NAME.tar.age"
age-keygen -o "$WORK/once.key" 2>/dev/null
once=$(age-keygen -y "$WORK/once.key")
tar -C "$WORK/plain" -cf "$WORK/backup.tar" "$(basename "$B")"
age -R "$AGE_RECIPIENTS" -r "$once" -o "$F" "$WORK/backup.tar"
rm -rf "$WORK/plain" "$WORK/backup.tar"
[ -s "$F" ] || fail "the encrypted file is empty"
( cd "$OUTABS" && sha256sum "$NAME.tar.age" > "$NAME.tar.age.sha256" )

# 4. the proof: open THIS file, delete the one-time key, restore into the empty target, compare every row count
mkdir "$WORK/check"
age -d -i "$WORK/once.key" -o "$WORK/check.tar" "$F" || fail "the encrypted file does not open"
rm -f "$WORK/once.key"
tar -C "$WORK/check" -xf "$WORK/check.tar"; rm -f "$WORK/check.tar"
C=$(ls -d "$WORK"/check/classi-backup-* 2>/dev/null | tail -1)
[ -n "$C" ] || fail "the encrypted file holds no backup folder"
if ! TARGET_URL="$TARGET_URL" sh "$HERE/restore-check.sh" "$C" > "$WORK/restore.log" 2>&1; then
  scrub "$WORK/restore.log"; fail "the restore proof failed: this backup is NOT usable"
fi
grep '^PASS' "$WORK/restore.log"

ntab=$(wc -l < "$C/counts.txt"); nrow=$(awk -F'|' '{s+=$2} END {print s+0}' "$C/counts.txt")
sha=$(cut -d' ' -f1 "$F.sha256"); size=$(wc -c < "$F")
cat > "$OUTABS/$NAME.summary.txt" <<EOF
backup     $NAME
source     cluster $cluster (staging marker), newest migration $m1
contents   $ntab tables, $nrow rows (schemas public, app_private and the accounts in auth; photo files are not included)
file       $NAME.tar.age, $size bytes, sha256 $sha
encrypted  age, to $keys owner key(s); the one-time key of the restore proof was deleted before the restore
restore    PASS: restored into an isolated empty database, every row count matches
EOF
cat "$OUTABS/$NAME.summary.txt"
echo "PASS: encrypted backup $NAME.tar.age, restore proven"
