-- classi-staging ONLY: applies migration 20261105010000_private_photos_enforce in one transaction and records it once.
-- Run in Supabase -> project classi-staging -> SQL Editor. It refuses to run on any other database (cluster id and the
-- 'staging' marker), if this migration is already recorded, or if the migration before it (20261105000000) is not. Any error
-- rolls everything back. The part between the BEGIN/END MIGRATION lines is the committed migration file, unchanged.
-- ORDER: apply only AFTER the app with private photos (Phase 7 code) is deployed to classi-staging; an older app
-- still uploads to the public bucket, which this refuses.
begin;
do $guard$ begin
  if (select system_identifier from pg_control_system()) <> 7702070854497379551 then raise exception 'refusing: not the classi-staging database'; end if;
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then raise exception 'refusing: database not marked staging'; end if;
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261105010000') then raise exception 'refusing: 20261105010000 is already recorded'; end if;
  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261105000000') then raise exception 'refusing: apply 20261105000000 first'; end if;
end $guard$;
-- ===== BEGIN MIGRATION supabase/migrations/20261105010000_private_photos_enforce.sql =====
-- Private photos, step B (enforcement). Apply ONLY after the app with the private flow is deployed (step 2 of
-- docs/hardening/PHASE-7-PRIVATE-PHOTOS-PLAN.md): an older app still uploads to the public bucket and saves public photo
-- links, which this refuses. Order on a hosted project: app code, then 20261105000000 (A), then this one (B).
--   * nobody but the admin can put a file in the public bucket "avatars" (users lose "upload own" and "replace own")
--   * a signed-in user (not an admin) can no longer set a public photo link: teachers.photo_url, institutes.logo_url
--     (also as a value waiting in pending_changes) and profiles.avatar_url may only be cleared; the live teacher /
--     institute photo is set by admin_publish_photo, the profile photo is profiles.avatar_path (private)
-- Server jobs (no signed-in user) are not affected. Rollback: supabase/rollback/20261105010000_private_photos_enforce.down.sql

drop policy if exists "avatars: upload own" on storage.objects;
drop policy if exists "avatars: replace own" on storage.objects;

create or replace function public.photo_publish_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_col text; v_new text; v_old text; v_pnew text; v_pold text;
begin
  if auth.uid() is null or is_admin() then return new; end if;
  if tg_table_name = 'teachers' then
    v_col := 'photo_url'; v_new := new.photo_url; v_pnew := new.pending_changes ->> 'photo_url';
    if tg_op = 'UPDATE' then v_old := old.photo_url; v_pold := old.pending_changes ->> 'photo_url'; end if;
  elsif tg_table_name = 'institutes' then
    v_col := 'logo_url'; v_new := new.logo_url; v_pnew := new.pending_changes ->> 'logo_url';
    if tg_op = 'UPDATE' then v_old := old.logo_url; v_pold := old.pending_changes ->> 'logo_url'; end if;
  else
    v_col := 'avatar_url'; v_new := new.avatar_url;
    if tg_op = 'UPDATE' then v_old := old.avatar_url; end if;
  end if;
  if (v_new is not null and v_new is distinct from v_old) or (v_pnew is not null and v_pnew is distinct from v_pold) then
    raise exception 'الصور تُرفع الآن بشكل خاص وتظهر بعد موافقة الإدارة (%).', v_col using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.photo_publish_guard() from anon, authenticated, public;

-- "zz_" after the content review (which moves a new photo into pending_changes first), like zz_photo_owner
drop trigger if exists zz_photo_publish on public.teachers;
create trigger zz_photo_publish before insert or update on public.teachers for each row execute function public.photo_publish_guard();
drop trigger if exists zz_photo_publish on public.institutes;
create trigger zz_photo_publish before insert or update on public.institutes for each row execute function public.photo_publish_guard();
drop trigger if exists zz_photo_publish on public.profiles;
create trigger zz_photo_publish before insert or update on public.profiles for each row execute function public.photo_publish_guard();
-- ===== END MIGRATION =====
insert into supabase_migrations.schema_migrations (version, name) values ('20261105010000', 'private_photos_enforce');
commit;
-- expected result: "Success. No rows returned"
