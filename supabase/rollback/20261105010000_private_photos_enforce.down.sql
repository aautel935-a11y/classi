-- Rollback of step B (20261105010000_private_photos_enforce): users may upload to their own folder of the public
-- bucket and set public photo links again (the policies as created in 20261024010000_photos_admin.sql).
-- On a hosted project, also remove the migration record afterwards:
--   delete from supabase_migrations.schema_migrations where version = '20261105010000';
begin;
drop trigger if exists zz_photo_publish on public.teachers;
drop trigger if exists zz_photo_publish on public.institutes;
drop trigger if exists zz_photo_publish on public.profiles;
drop function if exists public.photo_publish_guard();
drop policy if exists "avatars: upload own" on storage.objects;
create policy "avatars: upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "avatars: replace own" on storage.objects;
create policy "avatars: replace own" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
commit;
