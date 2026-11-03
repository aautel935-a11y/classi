-- classi-staging ONLY: applies migration 20261104000000_avatars_read_own in one transaction and records it once.
-- Run in Supabase -> project classi-staging -> SQL Editor. It refuses to run on any other database (cluster id and the
-- 'staging' marker), if this migration is already recorded, or if the phase-6 migrations before it are not. Any error
-- rolls everything back. The part between the BEGIN/END MIGRATION lines is the committed migration file, unchanged.
begin;
do $guard$ begin
  if (select system_identifier from pg_control_system()) <> 7702070854497379551 then raise exception 'refusing: not the classi-staging database'; end if;
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then raise exception 'refusing: database not marked staging'; end if;
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261104000000') then raise exception 'refusing: 20261104000000 is already recorded'; end if;
  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261103010000') then raise exception 'refusing: apply 20261103010000 first'; end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'avatars: read') then raise exception 'refusing: policy "avatars: read" not found (unexpected state)'; end if;
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
commit;
-- expected result: "Success. No rows returned"
