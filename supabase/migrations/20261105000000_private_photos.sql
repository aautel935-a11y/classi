-- Private photos, step A (additive; the current app keeps working unchanged).
-- Goal: a teacher's or institute's new photo is never public before the admin approves it, and the profile photos of
-- students and parents are seen by their owner only. Plan: docs/hardening/PHASE-7-PRIVATE-PHOTOS-PLAN.md
--   * bucket "photos-private" (not public): <owner>/pending/teacher-…jpg, <owner>/pending/institute-…jpg (waiting for
--     review) and <owner>/profile-…jpg (profile photos). Owner: upload/read/delete in their own folder, with exact file
--     names. Admin: read and delete waiting photos only (never profile photos), through signed links made with the
--     admin's own session.
--   * bucket "avatars" (public) keeps the approved teacher/institute photos. The admin may add one there when publishing
--     an approved photo, and read/delete teacher/institute photos (to replace the previous one). No service key needed.
--   * profiles.avatar_path: the private profile photo (path, not a public link).
--   * submit_photo(kind, path): the owner puts an uploaded private file up for review (teacher/institute) or as their
--     profile photo. admin_publish_photo(kind, id, path, url): after the admin copied the file to "avatars", sets the
--     live photo. admin_review(): approving other fields keeps a waiting photo waiting (it needs admin_publish_photo);
--     rejecting drops it.
--   * a signed-in user (not an admin) cannot put anything in pending_changes when creating a teacher / institute row
--     (only submit_photo and the content review write it), and admin_publish_photo only publishes a waiting photo
--     from the owner's own pending folder that still exists in the private bucket.
-- Step B (supabase/migrations/20261105010000_private_photos_enforce.sql) removes users' own uploads to the public bucket
-- and public photo links set by users.
-- Order on a hosted project: this migration (A), then the app code that uses the private flow, then B. The app code
-- before A fails (it calls submit_photo); B before the app code makes every photo upload of the old app fail.
-- Rollback: supabase/rollback/20261105000000_private_photos.down.sql. Safe on a live database: no data change.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos-private', 'photos-private', false, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

-- ---------- photos-private ----------
drop policy if exists "private photos: owner reads own" on storage.objects;
create policy "private photos: owner reads own" on storage.objects for select to authenticated
  using (bucket_id = 'photos-private' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "private photos: admin reads waiting" on storage.objects;
create policy "private photos: admin reads waiting" on storage.objects for select to authenticated
  using (bucket_id = 'photos-private' and (storage.foldername(name))[2] = 'pending' and is_admin());
drop policy if exists "private photos: owner uploads own" on storage.objects;
create policy "private photos: owner uploads own" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos-private'
              and name ~ ('^' || auth.uid()::text || '/(pending/(teacher|institute)|profile)-[0-9a-z]{1,12}-[0-9a-z]{8}\.jpg$'));
drop policy if exists "private photos: owner deletes own" on storage.objects;
create policy "private photos: owner deletes own" on storage.objects for delete to authenticated
  using (bucket_id = 'photos-private' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "private photos: admin deletes waiting" on storage.objects;
create policy "private photos: admin deletes waiting" on storage.objects for delete to authenticated
  using (bucket_id = 'photos-private' and (storage.foldername(name))[2] = 'pending' and is_admin());
-- (no update policy: files are never overwritten, every upload has its own name)

-- ---------- avatars: the admin publishes approved teacher/institute photos ----------
drop policy if exists "avatars: admin publishes approved photo" on storage.objects;
create policy "avatars: admin publishes approved photo" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and is_admin() and name ~ '^[0-9a-f-]{36}/(teacher|institute)-[0-9a-z]{1,12}-[0-9a-z]{8}\.jpg$');
drop policy if exists "avatars: admin reads teacher and institute photos" on storage.objects;
create policy "avatars: admin reads teacher and institute photos" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and is_admin() and name ~ '^[0-9a-f-]{36}/(teacher|institute)(-[0-9a-z]{1,12}-[0-9a-z]{8})?\.jpg$');
drop policy if exists "avatars: admin deletes teacher and institute photos" on storage.objects;
create policy "avatars: admin deletes teacher and institute photos" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and is_admin() and name ~ '^[0-9a-f-]{36}/(teacher|institute)(-[0-9a-z]{1,12}-[0-9a-z]{8})?\.jpg$');

-- ---------- profiles.avatar_path ----------
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles drop constraint if exists profiles_avatar_path_chk;
alter table public.profiles add constraint profiles_avatar_path_chk
  check (avatar_path is null or avatar_path ~ ('^' || id::text || '/profile-[0-9a-z]{1,12}-[0-9a-z]{8}\.jpg$'));

-- ---------- submit_photo ----------
create or replace function public.submit_photo(p_kind text, p_path text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_prev text; v_n int;
begin
  if v_uid is null then raise exception 'سجّل الدخول أولاً.'; end if;
  if p_kind not in ('teacher', 'institute', 'profile') then raise exception 'نوع غير معروف'; end if;
  if p_path is null or p_path !~ ('^' || v_uid::text || '/' || case when p_kind = 'profile' then 'profile' else 'pending/' || p_kind end
                                  || '-[0-9a-z]{1,12}-[0-9a-z]{8}\.jpg$') then
    raise exception 'الصورة يجب أن تكون من صور حسابك نفسه.';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'photos-private' and name = p_path) then
    raise exception 'لم يكتمل رفع الصورة، حاول مرة أخرى.';
  end if;
  if p_kind = 'profile' then
    select avatar_path into v_prev from profiles where id = v_uid;
    update profiles set avatar_path = p_path where id = v_uid;
    return v_prev;
  end if;
  -- the waiting photo is recorded as is (content review would otherwise rewrite pending_changes), for verified and
  -- not yet verified profiles alike: it is never public before the admin publishes it
  perform set_config('classi.bypass_review', 'on', true);
  if p_kind = 'teacher' then
    select pending_changes ->> 'photo_path' into v_prev from teachers where user_id = v_uid limit 1;
    update teachers set pending_changes = coalesce(pending_changes, '{}'::jsonb) || jsonb_build_object('photo_path', p_path) where user_id = v_uid;
  else
    select pending_changes ->> 'photo_path' into v_prev from institutes where owner_id = v_uid limit 1;
    update institutes set pending_changes = coalesce(pending_changes, '{}'::jsonb) || jsonb_build_object('photo_path', p_path) where owner_id = v_uid;
  end if;
  get diagnostics v_n = row_count;
  perform set_config('classi.bypass_review', '', true);
  if v_n = 0 then raise exception 'لا يوجد ملف %.', case when p_kind = 'teacher' then 'معلم' else 'معهد' end; end if;
  perform notify_admins(format('صورة %s جديدة بانتظار المراجعة', case when p_kind = 'teacher' then 'معلم' else 'معهد' end));
  return v_prev;
end $$;

-- ---------- admin_publish_photo ----------
create or replace function public.admin_publish_photo(p_kind text, p_id uuid, p_path text, p_url text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner uuid; v_waiting text; v_prev text; v_file text;
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_kind = 'teacher' then
    select user_id, pending_changes ->> 'photo_path', photo_url into v_owner, v_waiting, v_prev from teachers where id = p_id;
  elsif p_kind = 'institute' then
    select owner_id, pending_changes ->> 'photo_path', logo_url into v_owner, v_waiting, v_prev from institutes where id = p_id;
  else
    raise exception 'نوع غير معروف';
  end if;
  if v_owner is null then raise exception 'الملف غير موجود'; end if;
  if v_waiting is null or v_waiting is distinct from p_path then raise exception 'هذه ليست الصورة المنتظرة للمراجعة.'; end if;
  -- the waiting photo must be the owner's own (in their pending folder, for this kind) and still be in the private bucket
  if p_path !~ ('^' || v_owner::text || '/pending/' || p_kind || '-[0-9a-z]{1,12}-[0-9a-z]{8}\.jpg$')
     or not exists (select 1 from storage.objects where bucket_id = 'photos-private' and name = p_path) then
    raise exception 'الصورة المنتظرة ليست من صور صاحب الملف.';
  end if;
  v_file := substring(p_url from '/storage/v1/object/public/avatars/(.*)$');
  if p_url !~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/' || v_owner::text || '/' || p_kind || '-[0-9a-z]{1,12}-[0-9a-z]{8}\.jpg$')
     or not exists (select 1 from storage.objects where bucket_id = 'avatars' and name = v_file) then
    raise exception 'الصورة المعتمدة يجب أن تكون منشورة في مجلد صاحبها.';
  end if;
  if p_kind = 'teacher' then
    update teachers set photo_url = p_url, pending_changes = nullif(pending_changes - 'photo_path', '{}'::jsonb) where id = p_id;
  else
    update institutes set logo_url = p_url, pending_changes = nullif(pending_changes - 'photo_path', '{}'::jsonb) where id = p_id;
  end if;
  insert into notifications (user_id, kind, body, link)
  values (v_owner, 'review_answer', case when p_kind = 'teacher' then 'تمت الموافقة على صورتك، وهي ظاهرة الآن.' else 'تمت الموافقة على شعار المعهد، وهو ظاهر الآن.' end,
          case when p_kind = 'teacher' then '/teach' else '/manage' end);
  insert into moderation_actions (admin_id, target_type, target_id, action, reason) values (auth.uid(), p_kind, p_id, 'photo_publish', null);
  return v_prev;
end $$;

-- ---------- a new teacher / institute row cannot bring its own pending_changes or review_note ----------
-- Only submit_photo (the waiting photo) and the content review (edits of a verified profile) write pending_changes. Without
-- this, a user creating their row could put any photo_path there (for example a path in another user's folder).
create or replace function public.profile_insert_review() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null or is_admin() or coalesce(current_setting('classi.bypass_review', true), '') = 'on' then return new; end if;
  new.pending_changes := null;
  new.review_note := null;
  return new;
end $$;
revoke execute on function public.profile_insert_review() from anon, authenticated, public;
drop trigger if exists teachers_insert_review on public.teachers;
create trigger teachers_insert_review before insert on public.teachers for each row execute function public.profile_insert_review();
drop trigger if exists institutes_insert_review on public.institutes;
create trigger institutes_insert_review before insert on public.institutes for each row execute function public.profile_insert_review();

revoke execute on function public.submit_photo(text, text), public.admin_publish_photo(text, uuid, text, text) from anon, public;
grant execute on function public.submit_photo(text, text), public.admin_publish_photo(text, uuid, text, text) to authenticated;

-- ---------- admin_review: a waiting photo stays waiting when other fields are approved ----------
-- Same as 20261027010000_one_approval.sql, except the two lines that clear pending_changes on approval of a teacher /
-- institute: they now keep "photo_path" (published separately by admin_publish_photo). Rejection clears it as before.
create or replace function public.admin_review(p_kind text, p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner uuid; v_title text; v_changes jsonb; v_new boolean; v_note text := nullif(trim(p_note), '');
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_kind = 'offering' then
    select offering_owner_user(id), title, pending_changes, review_status <> 'approved' into v_owner, v_title, v_changes, v_new from offerings where id = p_id;
    if v_title is null then raise exception 'العرض غير موجود'; end if;
    if v_new then
      update offerings set review_status = case when p_approve then 'approved' else 'rejected' end, review_note = v_note, pending_changes = null where id = p_id;
      -- One approval is enough: a new teacher's / institute's first approved offer also approves their profile.
      if p_approve then
        update teachers set verify = 'verified' where verify = 'pending' and id = (select teacher_id from offerings where id = p_id);
        update institutes set verify = 'verified' where verify = 'pending' and id = (select institute_id from offerings where id = p_id);
      end if;
    elsif p_approve then
      update offerings set (title, subject_id, level_id, places, schedule_note, lessons_count, sessions_count, trial_price, package_enabled, package_size, package_price, minutes) =
        (select x.title, x.subject_id, x.level_id, x.places, x.schedule_note, x.lessons_count, x.sessions_count, x.trial_price, x.package_enabled, x.package_size, x.package_price, x.minutes
           from jsonb_populate_record(offerings, coalesce(v_changes, '{}'::jsonb)) x),
        pending_changes = null, review_note = v_note
       where id = p_id;
    else
      update offerings set pending_changes = null, review_note = v_note where id = p_id;
    end if;
    insert into notifications (user_id, kind, body, link)
    select v_owner, 'review_answer',
           case when p_approve then format('تمت الموافقة على %s: %s. %s', case when v_new then 'عرضك' else 'تعديلك على' end, v_title,
                                           case when v_new then 'العرض ظاهر الآن للطلاب.' else 'التعديل ظاهر الآن.' end)
                else format('لم تتم الموافقة على %s: %s.%s', case when v_new then 'عرضك' else 'تعديلك على' end, v_title, coalesce(' السبب: ' || v_note, '')) end,
           '/manage/course/' || p_id
     where v_owner is not null;
  elsif p_kind in ('teacher','institute') then
    if p_kind = 'teacher' then
      select user_id, name, pending_changes, verify = 'pending' into v_owner, v_title, v_changes, v_new from teachers where id = p_id;
      update teachers set verify = case when p_approve then 'verified' else 'rejected' end::verify_status where id = p_id and verify = 'pending';
      if p_approve then
        update teachers t set (name, bio, photo_url, intro_video_url, subject_id, years, is_school_teacher, town) =
          (select x.name, x.bio, x.photo_url, x.intro_video_url, x.subject_id, x.years, x.is_school_teacher, x.town
             from jsonb_populate_record(t, coalesce(v_changes, '{}'::jsonb)) x),
          pending_changes = case when v_changes ? 'photo_path' then jsonb_build_object('photo_path', v_changes -> 'photo_path') end, review_note = v_note where t.id = p_id;
      else
        update teachers set pending_changes = null, review_note = v_note where id = p_id;
      end if;
    else
      select owner_id, name, pending_changes, verify = 'pending' into v_owner, v_title, v_changes, v_new from institutes where id = p_id;
      update institutes set verify = case when p_approve then 'verified' else 'rejected' end::verify_status where id = p_id and verify = 'pending';
      if p_approve then
        update institutes i set (name, bio, logo_url, town) =
          (select x.name, x.bio, x.logo_url, x.town from jsonb_populate_record(i, coalesce(v_changes, '{}'::jsonb)) x),
          pending_changes = case when v_changes ? 'photo_path' then jsonb_build_object('photo_path', v_changes -> 'photo_path') end, review_note = v_note where i.id = p_id;
      else
        update institutes set pending_changes = null, review_note = v_note where id = p_id;
      end if;
    end if;
    insert into notifications (user_id, kind, body, link)
    select v_owner, 'review_answer',
           case when p_approve and v_new then 'تمت الموافقة على ملفك، وهو ظاهر الآن للطلاب مع عروضك الموافق عليها.'
                when p_approve then 'تمت الموافقة على تعديلات ملفك، وهي ظاهرة الآن.'
                when v_new then format('لم تتم الموافقة على ملفك.%s', coalesce(' السبب: ' || v_note, ''))
                else format('لم تتم الموافقة على تعديلات ملفك.%s', coalesce(' السبب: ' || v_note, '')) end,
           case when p_kind = 'teacher' then '/teach' else '/manage' end
     where v_owner is not null;
  else
    raise exception 'نوع غير معروف';
  end if;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), p_kind, p_id, case when p_approve then 'review_approve' else 'review_reject' end, v_note);
end $$;
