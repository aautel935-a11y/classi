-- classi-staging ONLY: applies migration 20261103000000_photo_owner_guard in one transaction and records it once.
-- Run in Supabase -> project classi-staging -> SQL Editor. It refuses to run on any other database (cluster id and the
-- 'staging' marker), and if the migration is already recorded. Any error rolls everything back; nothing is half-applied.
-- The part between the BEGIN/END MIGRATION lines is the committed migration file, unchanged.
begin;
do $guard$ begin
  if (select system_identifier from pg_control_system()) <> 7702070854497379551 then raise exception 'refusing: not the classi-staging database'; end if;
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then raise exception 'refusing: database not marked staging'; end if;
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261103000000') then raise exception 'refusing: 20261103000000 is already recorded'; end if;
end $guard$;
-- ===== BEGIN MIGRATION supabase/migrations/20261103000000_photo_owner_guard.sql =====
-- Phase 6: a photo link must point into its owner's own folder of the avatars bucket.
-- The app already checks this (lib/photos.ts validPhotoUrl), but the API can be called directly: without this, a user
-- could set another user's file as their profile photo (applied at once) or submit it as a teacher/institute photo.
--   teachers.photo_url (and a photo waiting in pending_changes)  -> folder = teachers.user_id
--   institutes.logo_url (and a logo waiting in pending_changes)  -> folder = institutes.owner_id
--   profiles.avatar_url                                          -> folder = profiles.id
-- Only values that CHANGE are checked, so existing rows (whatever they hold) never block an unrelated update, and no
-- table is scanned or rewritten. Server jobs (no signed-in user: migrations, staging data, cron) edit freely, as with
-- the content review. Rollback: supabase/rollback/20261103000000_photo_owner_guard.down.sql
-- Safe on a live database: two functions and three triggers, no data change, no lock beyond creating the triggers.

create or replace function public.photo_in_folder(p_url text, p_owner uuid) returns boolean
language sql immutable set search_path = public as $$
  select p_url is null
      or (p_owner is not null
          and p_url ~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/' || p_owner::text || '/[^/?#]+([?][^#]*)?$'))
$$;

-- security definer: runs with its owner's rights so it can call photo_in_folder(), which (like every internal function)
-- is not executable by app users; it only reads the row being written and the caller's id.
create or replace function public.photo_owner_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid; v_new text; v_old text; v_pnew text; v_pold text; v_col text;
begin
  if auth.uid() is null then return new; end if;
  if tg_table_name = 'teachers' then
    v_col := 'photo_url'; v_owner := new.user_id; v_new := new.photo_url;
    v_pnew := new.pending_changes ->> 'photo_url';
    if tg_op = 'UPDATE' then v_old := old.photo_url; v_pold := old.pending_changes ->> 'photo_url'; end if;
  elsif tg_table_name = 'institutes' then
    v_col := 'logo_url'; v_owner := new.owner_id; v_new := new.logo_url;
    v_pnew := new.pending_changes ->> 'logo_url';
    if tg_op = 'UPDATE' then v_old := old.logo_url; v_pold := old.pending_changes ->> 'logo_url'; end if;
  else
    v_col := 'avatar_url'; v_owner := new.id; v_new := new.avatar_url;
    if tg_op = 'UPDATE' then v_old := old.avatar_url; end if;
  end if;
  if (v_new is distinct from v_old and not photo_in_folder(v_new, v_owner))
     or (v_pnew is distinct from v_pold and not photo_in_folder(v_pnew, v_owner)) then
    raise exception 'الصورة يجب أن تكون من صور حسابك نفسه (%).', v_col using errcode = 'P0001';
  end if;
  return new;
end $$;

-- "zz_" so it runs after the other BEFORE triggers (teachers_review / institutes_review move a new photo into
-- pending_changes first): the final row, including the value waiting for review, is what gets checked.
drop trigger if exists zz_photo_owner on public.teachers;
create trigger zz_photo_owner before insert or update on public.teachers
  for each row execute function public.photo_owner_guard();
drop trigger if exists zz_photo_owner on public.institutes;
create trigger zz_photo_owner before insert or update on public.institutes
  for each row execute function public.photo_owner_guard();
drop trigger if exists zz_photo_owner on public.profiles;
create trigger zz_photo_owner before insert or update on public.profiles
  for each row execute function public.photo_owner_guard();

revoke execute on function public.photo_owner_guard(), public.photo_in_folder(text, uuid) from anon, authenticated, public;
-- ===== END MIGRATION =====
insert into supabase_migrations.schema_migrations (version, name) values ('20261103000000', 'photo_owner_guard');
commit;
-- expected result: "Success. No rows returned"
