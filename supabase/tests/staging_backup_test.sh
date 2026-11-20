#!/bin/sh
# Tests scripts/db/staging-backup.sh (the "Staging backup" workflow's script) on throwaway LOCAL databases with
# synthetic rows only: a fake "staging" source (auth.users, profiles, app_secrets with the staging marker, recorded
# migrations) and an empty target that has only what Supabase Auth would create. Never touches a hosted database.
# backup.sh takes its pg_dump path here (no Supabase CLI); the CI job "backup-drill" runs the Supabase CLI path.
# Every check prints PASS: or FAIL:.   Usage: sh supabase/tests/staging_backup_test.sh
set -u
T="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$T/../.." && pwd)"
S="$REPO/scripts/db/staging-backup.sh"
SOCK="${PGSOCK:-/var/tmp/pgc}"; PORT="${PGPORT:-54329}"
case "$SOCK" in
  /*) url() { echo "postgresql://postgres@/$1?host=$SOCK&port=$PORT"; } ;;
  *)  url() { echo "postgresql://postgres:${PGPASSWORD:-postgres}@$SOCK:$PORT/$1"; } ;;
esac
P="psql -X -h $SOCK -p $PORT -U postgres -q -v ON_ERROR_STOP=1"
SRC=ct_bk_src; TGT=ct_bk_tgt; TGT2=ct_bk_tgt2
W=$(mktemp -d); OUT="$W/out"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; fail=$((fail + 1)); }
auth_ddl="create schema auth;
create table auth.users (id uuid primary key, phone text unique, created_at timestamptz default now());"
fresh_target() {
  $P -c "drop database if exists $1" -c "create database $1" >/dev/null
  $P -d "$1" -c "$auth_ddl" >/dev/null
}
$P -c "drop database if exists $SRC" -c "create database $SRC" >/dev/null
$P -d "$SRC" >/dev/null <<SQL
$auth_ddl
create schema supabase_migrations;
create table supabase_migrations.schema_migrations (version text primary key);
insert into supabase_migrations.schema_migrations values ('20261114000000');
create table public.app_secrets (key text primary key, value text not null);
insert into public.app_secrets values ('deploy_env', 'staging');
create table public.profiles (id uuid primary key references auth.users(id), name text not null);
create table public.notifications (id bigserial primary key, user_id uuid references public.profiles(id), body text, sent boolean default false);
insert into auth.users (id, phone) select gen_random_uuid(), '+97250999' || lpad(g::text, 4, '0') from generate_series(1, 5) g;
insert into public.profiles select id, 'synthetic-person-' || right(phone, 4) from auth.users;
insert into public.notifications (user_id, body) select id, 'synthetic note ' || g from public.profiles, generate_series(1, 30) g;
SQL
fresh_target "$TGT"
CLUSTER=$($P -At -c "select system_identifier from pg_control_system()")
age-keygen -o "$W/owner.key" 2>/dev/null; age-keygen -y "$W/owner.key" > "$W/owner.pub"
age-keygen -o "$W/other.key" 2>/dev/null
src_fp() { $P -d "$SRC" -At -c "select md5(concat_ws('#', (select string_agg(id || phone, ',' order by id) from auth.users),
  (select string_agg(id || name, ',' order by id) from public.profiles), (select string_agg(id || body || sent, ',' order by id) from public.notifications),
  (select string_agg(key || value, ',' order by key) from public.app_secrets), (select string_agg(version, ',') from supabase_migrations.schema_migrations)))"; }
before=$(src_fp)
run() { mkdir -p "$W/tmp"; env TMPDIR="$W/tmp" DB_URL="$(url $SRC)" TARGET_URL="$(url $TGT)" AGE_RECIPIENTS="$W/owner.pub" EXPECT_CLUSTER="$CLUSTER" "$@" > "$W/log" 2>&1; }

# 1. the normal run
if run sh "$S" "$OUT" && grep -q '^PASS: encrypted backup' "$W/log" && grep -q '^PASS: 4 tables, every row count matches' "$W/log"; then ok "backup, encryption and restore proof: PASS"; else ko "normal run"; cat "$W/log"; fi
F=$(ls "$OUT"/classi-staging-*.tar.age 2>/dev/null | head -1)
[ -n "$F" ] && [ -s "$F.sha256" ] && [ -s "${F%.tar.age}.summary.txt" ] && ok "output: the encrypted file, its SHA-256 and a summary" || ko "output files"
[ "$(ls "$OUT" | wc -l)" = 3 ] && ok "nothing else in the output folder (no plaintext)" || { ko "extra files in the output"; ls "$OUT"; }
( cd "$OUT" && sha256sum -c --quiet "$(basename "$F").sha256" ) && ok "the SHA-256 matches the file" || ko "sha256"
grep -a -q -e synthetic -e '+97250999' -e deploy_env "$F" && ko "plaintext visible in the encrypted file" || ok "the encrypted file shows no content"
grep -q -e synthetic -e '+97250999' -e "$(cat "$W/owner.pub")" "$W/log" && ko "data or keys in the printed output" || ok "the printed output holds no data"
[ "$(src_fp)" = "$before" ] && ok "the source is unchanged" || ko "the source changed"
[ "$($P -d "$TGT" -At -c "select count(*) from public.notifications")" = 150 ] && ok "the target holds the restored rows (150 notifications)" || ko "target rows"

# 2. only the owner's key opens the stored file (the one-time key is gone)
mkdir "$W/open"
if age -d -i "$W/owner.key" "$F" | tar -C "$W/open" -xf - && [ -s "$W/open"/classi-backup-*/data.sql ]; then ok "the owner's key opens it (schema, data, counts, checksums)"; else ko "owner key"; fi
age -d -i "$W/other.key" "$F" > /dev/null 2>&1 && ko "another key opened it" || ok "another key cannot open it"
[ -z "$(ls -A "$W/tmp")" ] && ! grep -rqs 'AGE-SECRET-KEY' "$OUT" && ok "no temporary file and no private key left behind" || ko "temporary files or a private key left on disk"

# 3. the owner's later restore with open-backup.sh, from the stored file alone, into another empty database
fresh_target "$TGT2"
OB="$REPO/scripts/db/open-backup.sh"
if TARGET_URL="$(url $TGT2)" sh "$OB" "$F" "$W/owner.key" "$W/later" > "$W/log2" 2>&1 && grep -q '^ok: SHA-256 matches' "$W/log2" && grep -q '^ok: opened, every file matches' "$W/log2" && grep -q '^PASS' "$W/log2"; then
  ok "later restore by the owner (open-backup.sh: SHA-256, decrypt, inner checksums, restore): PASS"; else ko "later restore"; cat "$W/log2"; fi
grep -q -e synthetic -e '+97250999' "$W/log2" && ko "open-backup printed data" || ok "open-backup prints totals only"
cat "$W/owner.key" | sh "$OB" "$F" - "$W/later2" > "$W/log3" 2>&1 && grep -q '^ok: opened' "$W/log3" && ! grep -rqs 'AGE-SECRET-KEY' "$W/later2" \
  && ok "a key given on stdin (passphrase-protected key file) works and is not left on disk" || { ko "stdin key"; cat "$W/log3"; }
sh "$OB" "$F" "$W/other.key" "$W/later3" > "$W/log4" 2>&1 && ko "open-backup with another key: it opened" || { grep -q '^FAIL: this key does not open the file' "$W/log4" && [ ! -e "$W/later3/backup.tar" ] && ok "open-backup with another key: FAIL, nothing written" || ko "other key: $(tail -1 "$W/log4")"; }
sh "$OB" "$F" "$W/owner.key" "$W/later" > "$W/log5" 2>&1 && ko "open-backup into an existing folder: it ran" || ok "open-backup refuses an existing folder"
cp "$F" "$W/copy.tar.age"; sed "s/$(basename "$F")/copy.tar.age/" "$F.sha256" > "$W/copy.tar.age.sha256"; printf 'x' | dd of="$W/copy.tar.age" bs=1 seek=300 conv=notrunc 2>/dev/null
sh "$OB" "$W/copy.tar.age" "$W/owner.key" "$W/later4" > "$W/log6" 2>&1 && ko "open-backup of a damaged file: it opened" || { grep -q 'does not match its SHA-256' "$W/log6" && ok "open-backup of a damaged file: FAIL at the SHA-256" || ko "damaged: $(tail -1 "$W/log6")"; }

# 3b. the key check the owner runs once (check-backup-key.sh)
CK="$REPO/scripts/db/check-backup-key.sh"
sh "$CK" "$W/owner.key" "$(cat "$W/owner.pub")" | grep -q '^MATCH' && ok "key check: the right public key gives MATCH" || ko "key check match"
sh "$CK" "$W/owner.key" "$(age-keygen -y "$W/other.key")" > "$W/ck" 2>&1 && ko "key check: a wrong public key passed" || { grep -q '^NO MATCH' "$W/ck" && ok "key check: a wrong public key gives NO MATCH" || ko "key check mismatch"; }
sh "$CK" "$W/owner.key" "$(grep AGE-SECRET-KEY "$W/owner.key")" > "$W/ck" 2>&1 && ko "key check accepted a private key as the public one" || { grep -q '^STOP' "$W/ck" && ! grep -q 'AGE-SECRET-KEY-1' "$W/ck" && ok "key check: a private key pasted as the public one is stopped and not echoed" || ko "key check private"; }
cat "$W/owner.key" | sh "$CK" - "$(cat "$W/owner.pub")" | grep -q '^MATCH' && ok "key check from stdin" || ko "key check stdin"

# 4. damage is detected
cp "$F" "$W/bad.tar.age"; printf 'x' | dd of="$W/bad.tar.age" bs=1 seek=200 conv=notrunc 2>/dev/null
age -d -i "$W/owner.key" "$W/bad.tar.age" > /dev/null 2>&1 && ko "a damaged file opened" || ok "a damaged file is refused (authenticated encryption)"
( cd "$W" && sed "s/$(basename "$F")/bad.tar.age/" "$F.sha256" | sha256sum -c --quiet ) > /dev/null 2>&1 && ko "sha256 missed the damage" || ok "the SHA-256 shows the damage"

# 5. refusals (each must stop before writing anything)
refused() { # $1 label, $2 expected text, then the env overrides
  label="$1"; want="$2"; shift 2; rm -rf "$W/o2"
  fresh_target "$TGT"
  if env DB_URL="$(url $SRC)" TARGET_URL="$(url $TGT)" AGE_RECIPIENTS="$W/owner.pub" EXPECT_CLUSTER="$CLUSTER" "$@" sh "$S" "$W/o2" > "$W/log" 2>&1; then ko "$label: it ran"
  elif grep -q "$want" "$W/log" && [ -z "$(ls -A "$W/o2" 2>/dev/null)" ]; then ok "$label: refused"
  else ko "$label: $(tail -1 "$W/log")"; fi
}
refused "wrong cluster id" "not the expected one" EXPECT_CLUSTER=1234
refused "production URL" "production project" DB_URL="postgresql://postgres:x@db.rfxhqcagdsuhkjzwbawx.supabase.co:5432/postgres"
refused "URL of another project" "not the expected project" EXPECT_REF=nfipmylyahhogykikuqo
refused "remote source without EXPECT_REF" "only a local source" DB_URL="postgresql://postgres:x@db.example.com:5432/postgres"
refused "remote restore target" "must be a local database" TARGET_URL="postgresql://postgres:x@db.example.com:5432/postgres"
refused "target = source" "is the source" TARGET_URL="$(url $SRC)"
cp "$W/owner.key" "$W/priv.txt"; refused "private key given as recipient" "PRIVATE key" AGE_RECIPIENTS="$W/priv.txt"
printf 'not-a-key\n' > "$W/junk.txt"; refused "recipient that is not a key" "one age public key" AGE_RECIPIENTS="$W/junk.txt"
mkdir -p "$W/full"; : > "$W/full/old-file"
fresh_target "$TGT"
if env DB_URL="$(url $SRC)" TARGET_URL="$(url $TGT)" AGE_RECIPIENTS="$W/owner.pub" EXPECT_CLUSTER="$CLUSTER" sh "$S" "$W/full" > "$W/log" 2>&1; then ko "non-empty output folder: it ran"; else grep -q "must be empty" "$W/log" && [ "$(ls -A "$W/full")" = old-file ] && ok "non-empty output folder: refused" || ko "non-empty output: $(tail -1 "$W/log")"; fi
fresh_target "$TGT"
if env DB_URL="$(url $SRC)" TARGET_URL="$(url $TGT)" AGE_RECIPIENTS="$W/owner.pub" EXPECT_CLUSTER="$CLUSTER" sh "$S" "$REPO/tmp-backup-out" > "$W/log" 2>&1; then ko "output in repo: it ran"; else grep -q "outside the repository" "$W/log" && ok "output folder inside the repository: refused" || ko "output in repo: $(tail -1 "$W/log")"; fi
rm -rf "$REPO/tmp-backup-out"
$P -d "$TGT" -c "create table public.leftover (x int)" >/dev/null
if env DB_URL="$(url $SRC)" TARGET_URL="$(url $TGT)" AGE_RECIPIENTS="$W/owner.pub" EXPECT_CLUSTER="$CLUSTER" sh "$S" "$W/o3" > "$W/log" 2>&1; then ko "non-empty target: it ran"; else grep -q "not empty" "$W/log" && ok "non-empty restore target: refused" || ko "non-empty target: $(tail -1 "$W/log")"; fi
$P -d "$SRC" -c "delete from public.app_secrets where key = 'deploy_env'" >/dev/null
refused "source without the staging marker" "no staging marker"
$P -d "$SRC" -c "insert into public.app_secrets values ('deploy_env', 'staging')" >/dev/null

# 6. a restore that fails is reported as FAIL, without data in the output
fresh_target "$TGT"; $P -d "$TGT" -c "drop table auth.users; create table auth.users (id uuid primary key)" >/dev/null
if run sh "$S" "$W/o4"; then ko "broken target: it passed"
else grep -q 'FAIL: the restore proof failed' "$W/log" && ok "a failed restore gives FAIL" || ko "broken target: $(tail -1 "$W/log")"
  grep -q -e synthetic -e '+97250999' "$W/log" && ko "the FAIL output shows data" || ok "the FAIL output shows no data"; fi

$P -c "drop database if exists $SRC" -c "drop database if exists $TGT" -c "drop database if exists $TGT2" >/dev/null
echo "staging backup: $pass passed, $fail failed"
[ "$fail" = 0 ]
