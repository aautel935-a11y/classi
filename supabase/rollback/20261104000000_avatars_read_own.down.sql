-- Rollback of 20261104000000_avatars_read_own.sql: everyone can list the photos bucket again (the policy as created
-- in 20261024010000_photos_admin.sql). No data to restore (the migration changed none).
-- On a hosted project, also remove the migration record afterwards (Supabase -> SQL editor):
--   delete from supabase_migrations.schema_migrations where version = '20261104000000';
begin;
drop policy if exists "avatars: read own" on storage.objects;
drop policy if exists "avatars: read" on storage.objects;
create policy "avatars: read" on storage.objects for select using (bucket_id = 'avatars');
commit;
