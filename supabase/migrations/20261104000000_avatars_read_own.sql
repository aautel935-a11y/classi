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
