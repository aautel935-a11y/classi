-- Classi: nothing a teacher or institute publishes reaches students before an admin approves it.
--  · a new offer starts as "pending" and is hidden until approved
--  · changing a published offer's content, or a verified profile's name, bio, photo or video,
--    keeps the approved version live and holds the change for review
--  · admins get notified, approve or reject with a note, and the owner is told.
-- Operational settings (price, seats, hiding/showing, instant confirmation, weekly booking,
-- availability) still apply right away.

-- Default 'approved' covers rows written by the server itself (seed data); every offer a
-- teacher or institute creates is forced to 'pending' by the trigger below.
alter table public.offerings  add column if not exists review_status text not null default 'approved'
  check (review_status in ('pending','approved','rejected'));
alter table public.offerings  add column if not exists review_note text;
alter table public.offerings  add column if not exists pending_changes jsonb;
alter table public.teachers   add column if not exists pending_changes jsonb;
alter table public.institutes add column if not exists pending_changes jsonb;
alter table public.teachers   add column if not exists review_note text;
alter table public.institutes add column if not exists review_note text;


-- Students see an offer only when its owner is verified AND the offer itself is approved.
create or replace function public.offering_owner_verified(p_offering uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select review_status = 'approved' from offerings where id = p_offering), false) and coalesce(
    (select t.verify = 'verified' and not t.moderation_hidden and (t.user_id is null or is_active_user(t.user_id))
       from offerings o join teachers t on t.id = o.teacher_id where o.id = p_offering),
    (select i.verify = 'verified' and not i.moderation_hidden and (i.owner_id is null or is_active_user(i.owner_id))
       from offerings o join institutes i on i.id = o.institute_id where o.id = p_offering),
    false)
$$;

create or replace function public.notify_admins(p_body text, p_link text default '/admin?tab=review') returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, kind, body, link)
  select id, 'review_needed', p_body, p_link from profiles where 'admin' = any(roles)
$$;

-- ================= offers =================
create or replace function public.offerings_review() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  f text;
  v_new jsonb; v_old jsonb; v_pending jsonb := '{}'::jsonb;
  fields text[] := array['title','subject_id','level_id','places','schedule_note','lessons_count','sessions_count',
                         'trial_price','package_enabled','package_size','package_price','minutes'];
begin
  -- Admins and server jobs edit freely.
  if auth.uid() is null or is_admin() or coalesce(current_setting('classi.bypass_review', true), '') = 'on' then return new; end if;

  if tg_op = 'INSERT' then
    new.review_status := 'pending';
    new.review_note := null;
    new.pending_changes := null;
    perform notify_admins(format('عرض جديد بانتظار المراجعة: %s', new.title));
    return new;
  end if;

  -- Owners can never approve themselves.
  if new.review_status is distinct from old.review_status and not (old.review_status = 'rejected' and new.review_status = 'pending') then
    new.review_status := old.review_status;
  end if;
  new.review_note := old.review_note;

  -- A new or rejected offer that is edited simply goes (back) to the queue.
  if old.review_status <> 'approved' then
    if row(new.title, new.subject_id, new.level_id, new.places, new.schedule_note, new.trial_price, new.package_enabled, new.package_size, new.package_price)
       is distinct from row(old.title, old.subject_id, old.level_id, old.places, old.schedule_note, old.trial_price, old.package_enabled, old.package_size, old.package_price) then
      new.review_status := 'pending';
      if old.review_status = 'rejected' then perform notify_admins(format('عرض عُدّل بعد الرفض: %s', new.title)); end if;
    end if;
    return new;
  end if;

  -- A published offer stays live with its approved content; the change waits for review.
  v_new := to_jsonb(new); v_old := to_jsonb(old);
  foreach f in array fields loop
    if v_new -> f is distinct from v_old -> f then
      v_pending := v_pending || jsonb_build_object(f, v_new -> f);
    end if;
  end loop;
  if v_pending <> '{}'::jsonb then
    new := jsonb_populate_record(new, (select jsonb_object_agg(k, v_old -> k) from jsonb_object_keys(v_pending) k));
    new.pending_changes := coalesce(old.pending_changes, '{}'::jsonb) || v_pending;
    perform notify_admins(format('تعديل على عرض بانتظار المراجعة: %s', old.title));
  else
    new.pending_changes := old.pending_changes;
  end if;
  return new;
end $$;
drop trigger if exists offerings_review on public.offerings;
create trigger offerings_review before insert or update on public.offerings
  for each row execute function public.offerings_review();

-- ================= profiles (teachers, institutes) =================
create or replace function public.profile_review() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  f text; v_new jsonb; v_old jsonb; v_pending jsonb := '{}'::jsonb; fields text[];
begin
  if auth.uid() is null or is_admin() or coalesce(current_setting('classi.bypass_review', true), '') = 'on' then return new; end if;
  new.review_note := old.review_note;
  -- Not yet verified: the whole profile is reviewed at verification, so edits apply directly.
  if old.verify <> 'verified' then
    new.pending_changes := old.pending_changes;
    return new;
  end if;
  fields := case when tg_table_name = 'teachers'
                 then array['name','bio','photo_url','intro_video_url','subject_id','years','is_school_teacher','town']
                 else array['name','bio','logo_url','town'] end;
  v_new := to_jsonb(new); v_old := to_jsonb(old);
  foreach f in array fields loop
    if v_new ? f and v_new -> f is distinct from v_old -> f then
      v_pending := v_pending || jsonb_build_object(f, v_new -> f);
    end if;
  end loop;
  if v_pending <> '{}'::jsonb then
    new := jsonb_populate_record(new, (select jsonb_object_agg(k, v_old -> k) from jsonb_object_keys(v_pending) k));
    new.pending_changes := coalesce(old.pending_changes, '{}'::jsonb) || v_pending;
    perform notify_admins(format('تعديل ملف %s بانتظار المراجعة: %s', case when tg_table_name = 'teachers' then 'معلم' else 'معهد' end, old.name));
  else
    new.pending_changes := old.pending_changes;
  end if;
  return new;
end $$;
drop trigger if exists teachers_review on public.teachers;
create trigger teachers_review before update on public.teachers for each row execute function public.profile_review();
drop trigger if exists institutes_review on public.institutes;
create trigger institutes_review before update on public.institutes for each row execute function public.profile_review();

-- New teacher/institute profiles also tell the admins.
create or replace function public.profile_created_notify() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.verify <> 'verified' then
    perform notify_admins(format('%s جديد بانتظار التوثيق: %s', case when tg_table_name = 'teachers' then 'معلم' else 'معهد' end, new.name), '/admin?tab=verify');
  end if;
  return new;
end $$;
drop trigger if exists teachers_created_notify on public.teachers;
create trigger teachers_created_notify after insert on public.teachers for each row execute function public.profile_created_notify();
drop trigger if exists institutes_created_notify on public.institutes;
create trigger institutes_created_notify after insert on public.institutes for each row execute function public.profile_created_notify();

-- ================= admin review =================
create or replace function public.admin_review_queue()
returns table (kind text, id uuid, owner_name text, title text, what text, current jsonb, changes jsonb, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select 'offering', o.id, coalesce(t.name, i.name), o.title,
         case when o.review_status = 'pending' then 'new' else 'edit' end,
         jsonb_build_object('title', o.title, 'type', o.type, 'price', o.price, 'subject', s.name, 'level', l.name, 'places', o.places,
                            'schedule_note', o.schedule_note, 'trial_price', o.trial_price, 'package_enabled', o.package_enabled,
                            'package_size', o.package_size, 'package_price', o.package_price),
         o.pending_changes, o.created_at
    from offerings o left join teachers t on t.id = o.teacher_id left join institutes i on i.id = o.institute_id
    left join subjects s on s.id = o.subject_id left join levels l on l.id = o.level_id
   where is_admin() and (o.review_status = 'pending' or o.pending_changes is not null)
  union all
  select 'teacher', t.id, t.name, t.name, 'edit',
         jsonb_build_object('name', t.name, 'bio', t.bio, 'photo_url', t.photo_url, 'intro_video_url', t.intro_video_url, 'town', t.town, 'years', t.years),
         t.pending_changes, t.created_at
    from teachers t where is_admin() and t.pending_changes is not null
  union all
  select 'institute', i.id, i.name, i.name, 'edit',
         jsonb_build_object('name', i.name, 'bio', i.bio, 'logo_url', i.logo_url, 'town', i.town),
         i.pending_changes, i.created_at
    from institutes i where is_admin() and i.pending_changes is not null
  order by 8
$$;

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
      select user_id, name, pending_changes into v_owner, v_title, v_changes from teachers where id = p_id;
      if p_approve then
        update teachers t set (name, bio, photo_url, intro_video_url, subject_id, years, is_school_teacher, town) =
          (select x.name, x.bio, x.photo_url, x.intro_video_url, x.subject_id, x.years, x.is_school_teacher, x.town
             from jsonb_populate_record(t, coalesce(v_changes, '{}'::jsonb)) x),
          pending_changes = null, review_note = v_note where t.id = p_id;
      else
        update teachers set pending_changes = null, review_note = v_note where id = p_id;
      end if;
    else
      select owner_id, name, pending_changes into v_owner, v_title, v_changes from institutes where id = p_id;
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
           case when p_approve then 'تمت الموافقة على تعديلات ملفك، وهي ظاهرة الآن.'
                else format('لم تتم الموافقة على تعديلات ملفك.%s', coalesce(' السبب: ' || v_note, '')) end,
           case when p_kind = 'teacher' then '/teach' else '/manage' end
     where v_owner is not null;
  else
    raise exception 'نوع غير معروف';
  end if;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), p_kind, p_id, case when p_approve then 'review_approve' else 'review_reject' end, v_note);
end $$;

-- Review notifications reach the phone as well.
create or replace function public.notifications_mark_push() returns trigger
language plpgsql as $$
begin
  new.want_push := new.kind in ('reminder','reminder_soon','booking_answer','booking_request','booking_new','booking_cancelled',
                                'schedule_changed','waitlist_open','waitlist_answer','waitlist_join','verified','message',
                                'lesson_report','report_due','payment_reported','payment_answer','review_needed','review_answer');
  return new;
end $$;

revoke execute on function public.notify_admins, public.admin_review_queue, public.admin_review from anon, public;
grant execute on function public.admin_review_queue, public.admin_review to authenticated;
