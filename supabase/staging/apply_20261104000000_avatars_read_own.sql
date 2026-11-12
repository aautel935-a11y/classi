-- classi-staging ONLY: applies migration 20261104000000_avatars_read_own in one transaction and records it once.
-- Run in Supabase -> project classi-staging -> SQL Editor (never the GitHub "Staging database migrations" workflow: it
-- would apply every pending migration). Any error rolls everything back; nothing is changed unless every check passes.
-- Before any change it refuses unless:
--   - this is the classi-staging database (cluster id) AND it carries the 'staging' marker;
--   - the newest recorded migration is exactly 20261103010000 (so nothing newer, and 20261104000000 not yet recorded);
--   - row level security is on for storage.objects, and neither anon nor authenticated can bypass it;
--   - the photos bucket exists and is public;
--   - the policies on storage.objects are EXACTLY the four expected ones, compared in full (name, command,
--     permissive/restrictive, roles, USING, WITH CHECK). So: the old read policy must have its full expected definition
--     (SELECT, permissive, role public, USING bucket_id = 'avatars'); the new policy must not exist yet; and there is no
--     other policy of any kind (SELECT, ALL, restrictive, any bucket) that could widen or change reading.
-- After the change, still inside the transaction, it checks the result the same way (the four policies with the new read
-- policy, the other three unchanged) and fails (= rolls back) if it differs.
-- The part between the BEGIN/END MIGRATION lines is the committed migration file, unchanged (checked in CI).
-- Rollback: supabase/staging/rollback_20261104000000_avatars_read_own.sql (guarded, one transaction).
begin;
do $guard$
declare v_set text;
begin
  if (select system_identifier from pg_catalog.pg_control_system()) <> 7702070854497379551 then raise exception 'refusing: not the classi-staging database'; end if;
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then raise exception 'refusing: database not marked staging'; end if;
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261104000000') then raise exception 'refusing: 20261104000000 is already recorded'; end if;
  if (select max(version) from supabase_migrations.schema_migrations) is distinct from '20261103010000' then raise exception 'refusing: the newest recorded migration is not 20261103010000 (found %)', (select max(version) from supabase_migrations.schema_migrations); end if;
  if not (select relrowsecurity from pg_catalog.pg_class where oid = 'storage.objects'::regclass) then raise exception 'refusing: row level security is off on storage.objects'; end if;
  if exists (select 1 from pg_catalog.pg_roles where rolname in ('anon', 'authenticated') and rolbypassrls) then raise exception 'refusing: anon or authenticated bypasses row level security'; end if;
  if not exists (select 1 from storage.buckets where id = 'avatars' and public) then raise exception 'refusing: the photos bucket is missing or not public'; end if;
  select coalesce(string_agg(format('%s|%s|%s|%s|%s|%s', policyname, cmd, permissive, roles::text, coalesce(qual, '-'), coalesce(with_check, '-')), E'\n' order by policyname), '')
    into v_set from pg_catalog.pg_policies where schemaname = 'storage' and tablename = 'objects';
  if v_set is distinct from $exp$avatars: delete own|DELETE|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|-
avatars: read|SELECT|PERMISSIVE|{public}|(bucket_id = 'avatars'::text)|-
avatars: replace own|UPDATE|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
avatars: upload own|INSERT|PERMISSIVE|{authenticated}|-|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))$exp$
  then raise exception E'refusing: the policies on storage.objects are not exactly the expected four (unexpected state). Found:\n%', v_set; end if;
end $guard$;
-- ===== BEGIN MIGRATION supabase/migrations/20261104000000_avatars_read_own.sql =====
-- Photos bucket: a signed-in user can list (read the rows of) only their own folder.
-- Before: the policy "avatars: read" let everyone (visitors included, with the public app key) list the bucket:
-- the folder names (= user ids of everyone with a photo) and every file name in any folder. With a file name, the
-- public link opens the file, so photos waiting for admin review, or already rejected, could be found and opened
-- before or without approval, and profile photos of students and parents could be enumerated.
-- After: listing and reading the rows is limited to the owner's own folder (avatars/<user id>/...), the same rule as
-- upload, replace and delete. What the app needs is unchanged:
--   - public links (/storage/v1/object/public/avatars/...) do not use these policies: the bucket stays public;
--   - photo cleanup (app/actions.ts tidyPhotos) lists and deletes only the signed-in owner's own folder;
--   - the health check (lib/health.ts) lists the root: it now gets an empty list, without an error.
-- Not in scope: a file name obtained another way still opens through its public link (see
-- docs/hardening/PHASE-6-PENDING-PHOTOS.md). Rollback: supabase/rollback/20261104000000_avatars_read_own.down.sql
-- Safe on a live database: one policy replaced, no data change.

drop policy if exists "avatars: read" on storage.objects;
drop policy if exists "avatars: read own" on storage.objects;
create policy "avatars: read own" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
-- ===== END MIGRATION =====
insert into supabase_migrations.schema_migrations (version, name) values ('20261104000000', 'avatars_read_own');
do $check$
declare v_set text;
begin
  select coalesce(string_agg(format('%s|%s|%s|%s|%s|%s', policyname, cmd, permissive, roles::text, coalesce(qual, '-'), coalesce(with_check, '-')), E'\n' order by policyname), '')
    into v_set from pg_catalog.pg_policies where schemaname = 'storage' and tablename = 'objects';
  if v_set is distinct from $exp$avatars: delete own|DELETE|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|-
avatars: read own|SELECT|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|-
avatars: replace own|UPDATE|PERMISSIVE|{authenticated}|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))
avatars: upload own|INSERT|PERMISSIVE|{authenticated}|-|((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text))$exp$
  then raise exception E'aborting: the policies after the change are not the expected four; everything is rolled back. Found:\n%', v_set; end if;
  if (select max(version) from supabase_migrations.schema_migrations) is distinct from '20261104000000' then raise exception 'aborting: 20261104000000 is not the newest recorded migration after the change'; end if;
end $check$;
commit;
-- expected result: "Success. No rows returned"
