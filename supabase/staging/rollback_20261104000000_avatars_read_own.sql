-- classi-staging ONLY: rolls back migration 20261104000000_avatars_read_own in ONE transaction: the old read policy
-- and the migration record together. Run in Supabase -> project classi-staging -> SQL Editor. Any error rolls
-- everything back; nothing is changed unless every check passes.
-- Before any change it refuses unless:
--   - this is the classi-staging database (cluster id) AND it carries the 'staging' marker;
--   - 20261104000000 is recorded AND is the newest recorded migration (never roll back under a newer migration);
--   - row level security is on for storage.objects, and neither anon nor authenticated can bypass it;
--   - the photos bucket exists and is public;
--   - the policies on storage.objects are EXACTLY the four the apply file leaves, compared in full (name, command,
--     permissive/restrictive, roles, USING, WITH CHECK): "avatars: read own" as created, the other three unchanged,
--     "avatars: read" absent, and no other policy of any kind.
-- After the change, still inside the transaction, it checks that the state is exactly the one before the apply file
-- (the old read policy, the other three unchanged, newest migration 20261103010000) and fails (= rolls back) otherwise.
-- The part between the BEGIN/END ROLLBACK lines is supabase/rollback/20261104000000_avatars_read_own.down.sql without
-- its own begin/commit (checked in CI).
begin;
do $guard$
declare v_set text;
begin
  if (select system_identifier from pg_catalog.pg_control_system()) <> 7702070854497379551 then raise exception 'refusing: not the classi-staging database'; end if;
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then raise exception 'refusing: database not marked staging'; end if;
  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261104000000') then raise exception 'refusing: 20261104000000 is not recorded (nothing to roll back)'; end if;
  if (select max(version) from supabase_migrations.schema_migrations) is distinct from '20261104000000' then raise exception 'refusing: a newer migration is recorded (found %); roll it back first', (select max(version) from supabase_migrations.schema_migrations); end if;
  if not (select relrowsecurity from pg_catalog.pg_class where oid = 'storage.objects'::regclass) then raise exception 'refusing: row level security is off on storage.objects'; end if;
  if exists (select 1 from pg_catalog.pg_roles where rolname in ('anon', 'authenticated') and rolbypassrls) then raise exception 'refusing: anon or authenticated bypasses row level security'; end if;
  if not exists (select 1 from storage.buckets where id = 'avatars' and public) then raise exception 'refusing: the photos bucket is missing or not public'; end if;
  select coalesce(string_agg(format('%s|%s|%s|%s|%s|%s', policyname, cmd, permissive, roles::text, coalesce(qual, '-'), coalesce(with_check, '-')), E'\n' order by policyname), '')
    into v_set from pg_catalog.pg_policies where schemaname = 'storage' and tablename = 'objects';
  if v_set is distinct from $exp$avatars: delete own|DELETE|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|-
avatars: read own|SELECT|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|-
avatars: replace own|UPDATE|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
avatars: upload own|INSERT|PERMISSIVE|{authenticated}|-|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))$exp$
  then raise exception E'refusing: the policies on storage.objects are not exactly the four left by the apply file (unexpected state). Found:\n%', v_set; end if;
end $guard$;
-- ===== BEGIN ROLLBACK supabase/rollback/20261104000000_avatars_read_own.down.sql =====
drop policy if exists "avatars: read own" on storage.objects;
drop policy if exists "avatars: read" on storage.objects;
create policy "avatars: read" on storage.objects for select using (bucket_id = 'avatars');
-- ===== END ROLLBACK =====
delete from supabase_migrations.schema_migrations where version = '20261104000000';
do $check$
declare v_set text;
begin
  select coalesce(string_agg(format('%s|%s|%s|%s|%s|%s', policyname, cmd, permissive, roles::text, coalesce(qual, '-'), coalesce(with_check, '-')), E'\n' order by policyname), '')
    into v_set from pg_catalog.pg_policies where schemaname = 'storage' and tablename = 'objects';
  if v_set is distinct from $exp$avatars: delete own|DELETE|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|-
avatars: read|SELECT|PERMISSIVE|{public}|(bucket_id = 'avatars'::text)|-
avatars: replace own|UPDATE|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
avatars: upload own|INSERT|PERMISSIVE|{authenticated}|-|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))$exp$
  then raise exception E'aborting: the policies after the rollback are not the state before the apply file; everything is rolled back. Found:\n%', v_set; end if;
  if (select max(version) from supabase_migrations.schema_migrations) is distinct from '20261103010000' then raise exception 'aborting: the newest recorded migration after the rollback is not 20261103010000'; end if;
end $check$;
commit;
-- expected result: "Success. No rows returned"
