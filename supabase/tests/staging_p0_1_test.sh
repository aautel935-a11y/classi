#!/bin/sh
# Tests the classi-staging files of P0-1 (migration 20261104000000_avatars_read_own) on throwaway LOCAL databases that
# look like classi-staging just before P0-1: every migration up to 20261103010000 applied and recorded, the staging
# marker, the photos bucket. Never touches a hosted database.
#   supabase/staging/apply_20261104000000_avatars_read_own.sql
#   supabase/staging/rollback_20261104000000_avatars_read_own.sql
# The files only run on the classi-staging cluster id. To run them here, the test makes copies in which that one
# constant is replaced by this server's cluster id, and checks that nothing else differs.
# Every check prints PASS: or FAIL:. Usage: sh supabase/tests/staging_p0_1_test.sh   (local Postgres, or CI's service)
set -u
T="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$T/../.." && pwd)"
APPLY="$REPO/supabase/staging/apply_20261104000000_avatars_read_own.sql"
ROLLB="$REPO/supabase/staging/rollback_20261104000000_avatars_read_own.sql"
MIG="$REPO/supabase/migrations/20261104000000_avatars_read_own.sql"
DOWN="$REPO/supabase/rollback/20261104000000_avatars_read_own.down.sql"
STAGING_ID=7702070854497379551
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q"
W=$(mktemp -d); BASE=ct_p01_base; DB=ct_p01
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; fail=$((fail + 1)); }
q() { $P -d "$DB" -Atc "$1"; }
fresh() { $P -c "drop database if exists $DB" -c "create database $DB template $BASE" >/dev/null; }
# everything the files could change, as one fingerprint: storage.objects policies in full, RLS, the migration history,
# the marker, the bucket, the files
state() { q "select md5(concat_ws('#',
  (select string_agg(format('%s|%s|%s|%s|%s|%s', policyname, cmd, permissive, roles::text, coalesce(qual,'-'), coalesce(with_check,'-')), E'\n' order by policyname) from pg_policies where schemaname='storage' and tablename='objects'),
  (select relrowsecurity::text from pg_class where oid='storage.objects'::regclass),
  (select string_agg(version, ',' order by version) from supabase_migrations.schema_migrations),
  (select string_agg(key||'='||value, ',' order by key) from public.app_secrets where key='deploy_env'),
  (select string_agg(id||':'||public::text, ',') from storage.buckets),
  (select string_agg(bucket_id||'/'||name, ',' order by name) from storage.objects)))"; }
policies() { q "select string_agg(format('%s|%s|%s|%s|%s|%s', policyname, cmd, permissive, roles::text, coalesce(qual,'-'), coalesce(with_check,'-')), E'\n' order by policyname) from pg_policies where schemaname='storage' and tablename='objects'"; }
run() { $P -d "$DB" -v ON_ERROR_STOP=1 -f "$1" > "$W/out" 2>&1; }
# expect_refusal <label> <file> <text the refusal must contain>: refused, and nothing at all changed
expect_refusal() {
  before=$(state)
  if run "$2"; then ko "$1: it ran"; return; fi
  if ! grep -q "$3" "$W/out"; then ko "$1: not the expected refusal ($(grep -m1 ERROR "$W/out"))"; return; fi
  [ "$(state)" = "$before" ] && ok "$1 (refused, nothing changed)" || ko "$1: refused but the state changed"
}

# ---------- a database like classi-staging just before P0-1 ----------
$P -c "drop database if exists $BASE" -c "create database $BASE" >/dev/null
D="env PGOPTIONS=-cclient_min_messages=warning $P -d $BASE -v ON_ERROR_STOP=1"
$D -f "$T/supabase_stub.sql" >/dev/null
$D -c "create schema if not exists supabase_migrations; create table if not exists supabase_migrations.schema_migrations (version text primary key, name text, statements text[])" >/dev/null
for f in "$REPO"/supabase/migrations/*.sql; do
  v=$(basename "$f" | cut -d_ -f1); [ "$v" \> 20261103010000 ] && break
  $D -f "$f" >/dev/null || { echo "FAIL: base: $f did not apply"; exit 1; }
  $D -c "insert into supabase_migrations.schema_migrations (version, name) values ('$v', '$(basename "$f" .sql | cut -d_ -f2-)')" >/dev/null
done
$D -c "insert into public.app_secrets (key, value) values ('deploy_env', 'staging') on conflict (key) do update set value = excluded.value" >/dev/null
DB=$BASE; BASE_STATE=$(state); BASE_POLICIES=$(policies); DB=ct_p01
LOCAL_ID=$($P -d $BASE -Atc "select system_identifier from pg_control_system()")

# ---------- the files themselves ----------
for f in "$APPLY" "$ROLLB"; do
  n=$(grep -c "$STAGING_ID" "$f"); [ "$n" = 1 ] && ok "$(basename "$f"): the staging cluster id appears exactly once" || ko "$(basename "$f"): cluster id appears $n times"
done
sed "s/$STAGING_ID/$LOCAL_ID/" "$APPLY" > "$W/apply.sql"; sed "s/$STAGING_ID/$LOCAL_ID/" "$ROLLB" > "$W/rollback.sql"
[ "$(diff "$APPLY" "$W/apply.sql" | grep -c '^[<>]')" = 2 ] && ok "test copy of the apply file differs only in the cluster id line" || ko "apply test copy differs in more than the cluster id"
[ "$(diff "$ROLLB" "$W/rollback.sql" | grep -c '^[<>]')" = 2 ] && ok "test copy of the rollback file differs only in the cluster id line" || ko "rollback test copy differs in more than the cluster id"
awk '/^-- ===== BEGIN MIGRATION/{f=1;next}/^-- ===== END MIGRATION/{f=0}f' "$APPLY" | cmp -s - "$MIG" \
  && ok "the migration inside the apply file is the committed migration file, byte for byte" || ko "embedded migration differs from $MIG"
awk '/^-- ===== BEGIN ROLLBACK/{f=1;next}/^-- ===== END ROLLBACK/{f=0}f' "$ROLLB" > "$W/body"
grep -v '^--' "$DOWN" | grep -v '^begin;$' | grep -v '^commit;$' | cmp -s - "$W/body" \
  && ok "the rollback inside the rollback file is the committed down file (without its begin/commit)" || ko "embedded rollback differs from $DOWN"
[ "$(grep -ciE '^\s*(grant|revoke|alter|truncate|update|create (table|function|role))' "$APPLY")" = 0 ] && ok "apply file: no grant, revoke, alter, truncate, update or new table/function/role" || ko "apply file has statements outside its scope"
[ "$(grep -ciE '^\s*(grant|revoke|alter|truncate|update|create (table|function|role))' "$ROLLB")" = 0 ] && ok "rollback file: no grant, revoke, alter, truncate, update or new table/function/role" || ko "rollback file has statements outside its scope"
grep -qiE '\\i|\\include|\\ir' "$APPLY" "$ROLLB" && ko "a file includes another file" || ok "neither file includes or calls another migration file"

# ---------- the old policy lets anyone list (the isolation checks below must catch it) ----------
seed_files() {
  q "insert into auth.users (id, email) values ('73000000-0000-0000-0000-00000000000a','a@t'), ('73000000-0000-0000-0000-00000000000b','b@t')" >/dev/null
  q "insert into storage.objects (bucket_id, name) values ('avatars','73000000-0000-0000-0000-00000000000a/teacher-a1-aaaaaaaa.jpg'), ('avatars','73000000-0000-0000-0000-00000000000a/teacher-p1-pppppppp.jpg'), ('avatars','73000000-0000-0000-0000-00000000000b/profile-b1-bbbbbbbb.jpg')" >/dev/null
}
as_anon() { q "set role anon; reset request.jwt.claim.sub; $1"; }
as_user() { q "set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-00000000000$1'; $2"; }
isolation() { # prints the number of failed isolation checks
  n=0
  [ "$(as_anon "select count(*) from storage.objects where bucket_id='avatars'")" = 0 ] || n=$((n+1))
  [ "$(as_anon "select count(distinct (storage.foldername(name))[1]) from storage.objects where bucket_id='avatars'")" = 0 ] || n=$((n+1))
  [ "$(as_user b "select count(*) from storage.objects where bucket_id='avatars' and name like '73000000-0000-0000-0000-00000000000a/%'")" = 0 ] || n=$((n+1))
  [ "$(as_user b "select coalesce(string_agg(distinct (storage.foldername(name))[1], ','), '') from storage.objects where bucket_id='avatars'")" = 73000000-0000-0000-0000-00000000000b ] || n=$((n+1))
  [ "$(as_user a "select count(*) from storage.objects where bucket_id='avatars' and name like '73000000-0000-0000-0000-00000000000a/%'")" = 2 ] || n=$((n+1))
  [ "$(as_user a "select count(*) from storage.objects where bucket_id='avatars' and name not like '73000000-0000-0000-0000-00000000000a/%'")" = 0 ] || n=$((n+1))
  echo $n
}
fresh; seed_files
n=$(isolation); [ "$n" -ge 4 ] && ok "before P0-1 the isolation checks fail ($n of 6): the open listing is real and the checks see it" || ko "before P0-1 only $n isolation checks fail; the checks prove nothing"

# ---------- apply: refusals (each on a fresh copy; nothing may change) ----------
fresh; expect_refusal "apply outside classi-staging (the committed file, real cluster id)" "$APPLY" "refusing: not the classi-staging database"
fresh; q "delete from public.app_secrets where key='deploy_env'" >/dev/null
expect_refusal "apply without the staging marker" "$W/apply.sql" "refusing: database not marked staging"
fresh; q "insert into supabase_migrations.schema_migrations (version, name) values ('20261105000000','private_photos')" >/dev/null
expect_refusal "apply with a newer migration recorded" "$W/apply.sql" "newest recorded migration is not 20261103010000"
fresh; q "insert into supabase_migrations.schema_migrations (version, name) values ('20261104000000','avatars_read_own')" >/dev/null
expect_refusal "apply when 20261104000000 is already recorded" "$W/apply.sql" "already recorded"
fresh; q "delete from supabase_migrations.schema_migrations where version='20261103010000'" >/dev/null
expect_refusal "apply when 20261103010000 is not the newest (older history)" "$W/apply.sql" "newest recorded migration is not 20261103010000"
fresh; q "drop policy \"avatars: read\" on storage.objects; create policy \"avatars: read\" on storage.objects for select to anon using (bucket_id = 'avatars')" >/dev/null
expect_refusal "apply when the old policy has other roles (to anon)" "$W/apply.sql" "not exactly the expected four"
fresh; q "drop policy \"avatars: read\" on storage.objects; create policy \"avatars: read\" on storage.objects for select using (true)" >/dev/null
expect_refusal "apply when the old policy has another USING (true)" "$W/apply.sql" "not exactly the expected four"
fresh; q "drop policy \"avatars: read\" on storage.objects; create policy \"avatars: read\" on storage.objects for all using (bucket_id = 'avatars')" >/dev/null
expect_refusal "apply when the old policy is FOR ALL instead of SELECT" "$W/apply.sql" "not exactly the expected four"
fresh; q "drop policy \"avatars: read\" on storage.objects; create policy \"avatars: read\" on storage.objects as restrictive for select using (bucket_id = 'avatars')" >/dev/null
expect_refusal "apply when the old policy is restrictive" "$W/apply.sql" "not exactly the expected four"
fresh; q "drop policy \"avatars: read\" on storage.objects" >/dev/null
expect_refusal "apply when the old policy is missing" "$W/apply.sql" "not exactly the expected four"
fresh; q "create policy \"avatars: read own\" on storage.objects for select to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)" >/dev/null
expect_refusal "apply when the new policy already exists" "$W/apply.sql" "not exactly the expected four"
fresh; q "create policy \"anything: read\" on storage.objects for select to authenticated using (true)" >/dev/null
expect_refusal "apply with another permissive SELECT policy (wider read)" "$W/apply.sql" "not exactly the expected four"
fresh; q "create policy \"anything: all\" on storage.objects for all to public using (bucket_id <> 'other')" >/dev/null
expect_refusal "apply with a FOR ALL policy (it also grants reading)" "$W/apply.sql" "not exactly the expected four"
fresh; q "create policy \"other bucket: read\" on storage.objects for select using (bucket_id = 'other')" >/dev/null
expect_refusal "apply with a policy for another bucket (unexpected state)" "$W/apply.sql" "not exactly the expected four"
fresh; q "create policy \"narrow\" on storage.objects as restrictive for select using (true)" >/dev/null
expect_refusal "apply with a restrictive policy (unexpected state)" "$W/apply.sql" "not exactly the expected four"
fresh; q "alter table storage.objects disable row level security" >/dev/null
expect_refusal "apply when row level security is off" "$W/apply.sql" "row level security is off"
fresh; q "update storage.buckets set public = false where id = 'avatars'" >/dev/null
expect_refusal "apply when the photos bucket is not public" "$W/apply.sql" "missing or not public"
fresh; $P -c "alter role anon bypassrls" >/dev/null
expect_refusal "apply when anon bypasses row level security" "$W/apply.sql" "bypasses row level security"
$P -c "alter role anon nobypassrls" >/dev/null
# the check after the change: a wrong expected result must undo everything (policy and record)
sed 's/^avatars: read own|SELECT|/avatars: read own|NOT-SELECT|/' "$W/apply.sql" > "$W/apply_badcheck.sql"
fresh; expect_refusal "apply whose result check fails is rolled back completely (policy and record)" "$W/apply_badcheck.sql" "aborting: the policies after the change"

# ---------- apply: success ----------
fresh; seed_files; files_before=$(q "select string_agg(name, ',' order by name) from storage.objects")
if run "$W/apply.sql"; then ok "apply runs on a database like classi-staging"; else ko "apply failed: $(grep -m1 ERROR "$W/out")"; fi
[ "$(q "select max(version) from supabase_migrations.schema_migrations")" = 20261104000000 ] && ok "apply records 20261104000000, the newest" || ko "migration record after apply"
[ "$(q "select count(*) from supabase_migrations.schema_migrations where version='20261104000000'")" = 1 ] && ok "apply records it exactly once" || ko "record count"
[ "$(q "select count(*) from pg_policies where schemaname='storage' and tablename='objects' and policyname='avatars: read'")" = 0 ] && ok "the old read policy is gone" || ko "old policy still there"
[ "$(q "select cmd||'|'||permissive||'|'||roles::text||'|'||qual||'|'||coalesce(with_check,'-') from pg_policies where policyname='avatars: read own'")" = "SELECT|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|-" ] \
  && ok "the new policy: SELECT, permissive, authenticated only, own folder only" || ko "new policy definition"
[ "$(policies | grep -v '^avatars: read')" = "$(echo "$BASE_POLICIES" | grep -v '^avatars: read')" ] && ok "the other three policies are unchanged, in full" || ko "another policy changed"
[ "$(q "select string_agg(name, ',' order by name) from storage.objects")" = "$files_before" ] && ok "no file row was added, changed or removed" || ko "files changed"
[ "$(q "select string_agg(id||':'||public::text, ',') from storage.buckets")" = "avatars:true" ] && ok "the photos bucket is still public" || ko "bucket changed"
n=$(isolation); [ "$n" = 0 ] && ok "after P0-1: visitors list nothing, no user sees another user's folder or name at the root, the owner lists only his own" || ko "after P0-1: $n isolation checks fail"
after_apply=$(state)

# ---------- rollback: refusals ----------
expect_refusal "rollback outside classi-staging (the committed file, real cluster id)" "$ROLLB" "refusing: not the classi-staging database"
q "delete from public.app_secrets where key='deploy_env'" >/dev/null
expect_refusal "rollback without the staging marker" "$W/rollback.sql" "refusing: database not marked staging"
q "insert into public.app_secrets (key, value) values ('deploy_env','staging')" >/dev/null
q "insert into supabase_migrations.schema_migrations (version, name) values ('20261105000000','private_photos')" >/dev/null
expect_refusal "rollback with a newer migration recorded" "$W/rollback.sql" "a newer migration is recorded"
q "delete from supabase_migrations.schema_migrations where version='20261105000000'" >/dev/null
q "create policy \"anything: read\" on storage.objects for select to authenticated using (true)" >/dev/null
expect_refusal "rollback with an extra policy (unexpected state)" "$W/rollback.sql" "not exactly the four left by the apply file"
q "drop policy \"anything: read\" on storage.objects" >/dev/null
q "drop policy \"avatars: read own\" on storage.objects; create policy \"avatars: read own\" on storage.objects for select using (bucket_id = 'avatars')" >/dev/null
expect_refusal "rollback when the new policy was changed (unexpected state)" "$W/rollback.sql" "not exactly the four left by the apply file"
q "drop policy \"avatars: read own\" on storage.objects; create policy \"avatars: read own\" on storage.objects for select to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)" >/dev/null
q "create policy \"avatars: read\" on storage.objects for select using (bucket_id = 'avatars')" >/dev/null
expect_refusal "rollback when the old policy is back already (unexpected state)" "$W/rollback.sql" "not exactly the four left by the apply file"
q "drop policy \"avatars: read\" on storage.objects" >/dev/null
q "alter table storage.objects disable row level security" >/dev/null
expect_refusal "rollback when row level security is off" "$W/rollback.sql" "row level security is off"
q "alter table storage.objects enable row level security" >/dev/null
[ "$(state)" = "$after_apply" ] && ok "(test setup restored to the state after apply)" || ko "test setup not restored"
sed 's/^avatars: read|SELECT|PERMISSIVE|{public}|/avatars: read|NOT-SELECT|PERMISSIVE|{public}|/' "$W/rollback.sql" > "$W/rollback_badcheck.sql"
expect_refusal "rollback whose result check fails is rolled back completely (policy and record)" "$W/rollback_badcheck.sql" "aborting: the policies after the rollback"

# ---------- rollback: success, then a second full cycle ----------
if run "$W/rollback.sql"; then ok "rollback runs after apply"; else ko "rollback failed: $(grep -m1 ERROR "$W/out")"; fi
q "delete from storage.objects where name like '73000000-%'; delete from auth.users where id::text like '73000000-%'" >/dev/null
[ "$(state)" = "$BASE_STATE" ] && ok "after rollback the state is exactly the one before P0-1 (policies in full, RLS, migration history, marker, bucket, files)" || ko "rollback did not restore the state before P0-1"
fresh; expect_refusal "rollback when 20261104000000 was never applied" "$W/rollback.sql" "is not recorded"
run "$W/apply.sql" && run "$W/rollback.sql" && run "$W/apply.sql" && [ "$(q "select max(version) from supabase_migrations.schema_migrations")" = 20261104000000 ] \
  && run "$W/rollback.sql" && [ "$(state)" = "$BASE_STATE" ] && ok "apply, rollback, apply, rollback: back to the exact state before P0-1" || ko "second cycle"

$P -c "drop database if exists $DB" -c "drop database if exists $BASE" >/dev/null 2>&1; rm -rf "$W"
echo "staging P0-1 files: $pass passed, $fail failed"
[ "$fail" = 0 ]
