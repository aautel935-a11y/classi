-- Rollback of step A (20261105000000_private_photos): removes the private-photo policies and functions and puts
-- admin_review back as in 20261027010000_one_approval.sql. On purpose NOT removed, so no file or data is lost:
-- the bucket "photos-private" (its files stay, unreachable for users) and the column profiles.avatar_path.
-- Before rolling back: decide (approve/reject) waiting private photos. Roll back step B first if it was applied.
-- On a hosted project, also remove the migration record afterwards:
--   delete from supabase_migrations.schema_migrations where version = '20261105000000';
begin;
drop policy if exists "private photos: owner reads own" on storage.objects;
drop policy if exists "private photos: admin reads waiting" on storage.objects;
drop policy if exists "private photos: owner uploads own" on storage.objects;
drop policy if exists "private photos: owner deletes own" on storage.objects;
drop policy if exists "private photos: admin deletes waiting" on storage.objects;
drop policy if exists "avatars: admin publishes approved photo" on storage.objects;
drop policy if exists "avatars: admin reads teacher and institute photos" on storage.objects;
drop policy if exists "avatars: admin deletes teacher and institute photos" on storage.objects;
drop function if exists public.submit_photo(text, text);
drop function if exists public.admin_publish_photo(text, uuid, text, text);
create or replace function public.admin_review(p_kind text, p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
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
          pending_changes = null, review_note = v_note where t.id = p_id;
      else
        update teachers set pending_changes = null, review_note = v_note where id = p_id;
      end if;
    else
      select owner_id, name, pending_changes, verify = 'pending' into v_owner, v_title, v_changes, v_new from institutes where id = p_id;
      update institutes set verify = case when p_approve then 'verified' else 'rejected' end::verify_status where id = p_id and verify = 'pending';
      if p_approve then
        update institutes i set (name, bio, logo_url, town) =
          (select x.name, x.bio, x.logo_url, x.town from jsonb_populate_record(i, coalesce(v_changes, '{}'::jsonb)) x),
          pending_changes = null, review_note = v_note where i.id = p_id;
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
commit;
