-- Rollback of 20261103000000_photo_owner_guard.sql: removes the owner-folder check on photo links.
-- No data to restore (the migration changed none). After this, only the app checks the folder (lib/photos.ts).
-- On a hosted project, also remove the migration record afterwards (Supabase -> SQL editor):
--   delete from supabase_migrations.schema_migrations where version = '20261103000000';
begin;
drop trigger if exists zz_photo_owner on public.teachers;
drop trigger if exists zz_photo_owner on public.institutes;
drop trigger if exists zz_photo_owner on public.profiles;
drop function if exists public.photo_owner_guard();
drop function if exists public.photo_in_folder(text, uuid);
commit;
