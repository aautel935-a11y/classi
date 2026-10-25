-- Classi: day-to-day operations before launch.
--  1. group meetings keep going (always 8 weeks ahead) and a single meeting can be cancelled
--  2. lesson length is the teacher's choice (no approval needed)
--  3. course installments: 3 payments tracked one by one
--  4. vacation: close whole days at once
--  5. institutes enroll walk-in students by hand, and can remove a teacher from their staff

-- Walk-in students (no Classi account) are bookings kept under a name.
alter table public.bookings alter column booked_by drop not null;
alter table public.bookings add column if not exists offline_name text check (char_length(offline_name) <= 80);
alter table public.bookings add column if not exists offline_phone text;
alter table public.lesson_reports alter column student_user drop not null;

-- Notifications to nobody (walk-in students without an account) are simply skipped.
create or replace function public.notifications_skip_nobody() returns trigger
language plpgsql as $$ begin if new.user_id is null then return null; end if; return new; end $$;
drop trigger if exists notifications_a_skip_nobody on public.notifications;
create trigger notifications_a_skip_nobody before insert on public.notifications
  for each row execute function public.notifications_skip_nobody();

-- ================= 1. group meetings =================
-- Weekly groups have no end date: keep 8 weeks of meetings ahead, same weekday/time/room/length as the last one.
create or replace function public.extend_group_sessions() returns int
language plpgsql security definer set search_path = public as $$
declare o record; v_last sessions%rowtype; v_next timestamptz; v_n int := 0;
begin
  for o in select id from offerings where type = 'group' and active and not moderation_hidden loop
    loop
      select * into v_last from sessions where offering_id = o.id order by starts_at desc limit 1;
      exit when v_last.id is null;
      v_next := ((v_last.starts_at at time zone 'Asia/Jerusalem') + interval '7 days') at time zone 'Asia/Jerusalem';
      exit when v_next > now() + interval '8 weeks';
      insert into sessions (offering_id, seq, starts_at, minutes, room_id)
      values (o.id, v_last.seq + 1, v_next, v_last.minutes, v_last.room_id);
      v_n := v_n + 1;
    end loop;
  end loop;
  -- Weekly subscribers get a seat in the new meetings.
  perform extend_recurring();
  return v_n;
end $$;

-- Cancel one meeting (holiday, illness): its seats are released and everyone booked is told.
create or replace function public.cancel_session(p_session uuid, p_reason text default null) returns int
language plpgsql security definer set search_path = public as $$
declare s sessions%rowtype; o offerings%rowtype; v_n int := 0; v_reason text := nullif(trim(p_reason), ''); v_course_teacher uuid;
begin
  select * into s from sessions where id = p_session;
  if not found then raise exception 'اللقاء غير موجود'; end if;
  select * into o from offerings where id = s.offering_id;
  if not is_offering_owner(o.id) then raise exception 'إلغاء اللقاءات لصاحب العرض فقط'; end if;
  if s.cancelled then raise exception 'اللقاء ملغى سابقاً'; end if;
  if s.starts_at < now() then raise exception 'لا يمكن إلغاء لقاء انتهى'; end if;
  update sessions set cancelled = true where id = s.id;

  -- Group seats for that meeting are cancelled (package lessons return automatically).
  update bookings set status = 'cancelled' where session_id = s.id and status in ('pending','confirmed');
  get diagnostics v_n = row_count;

  -- Tell everyone booked: group bookings of the meeting, or every course student.
  insert into notifications (user_id, kind, body, link)
  select distinct b.booked_by, 'schedule_changed',
         format('أُلغي لقاء %s يوم %s.%s', o.title, fmt_time(s.starts_at), coalesce(' «' || v_reason || '»', '')), '/schedule'
    from bookings b
   where (b.session_id = s.id or (o.type = 'course' and b.offering_id = o.id and b.session_id is null and b.status in ('pending','confirmed')))
     and b.booked_by is not null;
  -- and the course teacher, if it is an institute course
  select user_id into v_course_teacher from teachers where id = o.course_teacher_id;
  if v_course_teacher is not null and v_course_teacher <> auth.uid() then
    insert into notifications (user_id, kind, body, link)
    values (v_course_teacher, 'schedule_changed', format('أُلغي لقاء %s يوم %s.%s', o.title, fmt_time(s.starts_at), coalesce(' «' || v_reason || '»', '')), '/teach');
  end if;
  if o.institute_id is not null then
    insert into change_log (offering_id, changed_by, body, notified_count)
    values (o.id, auth.uid(), format('أُلغي اللقاء %s (%s)%s', s.seq, fmt_time(s.starts_at), coalesce(': ' || v_reason, '')),
            (select count(distinct booked_by) from bookings where offering_id = o.id and status in ('pending','confirmed')));
  end if;
  return v_n;
end $$;

-- ================= 2. lesson length: operational, not reviewed =================
create or replace function public.offerings_review() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  f text;
  v_new jsonb; v_old jsonb; v_pending jsonb := '{}'::jsonb;
  fields text[] := array['title','subject_id','level_id','places','schedule_note','lessons_count','sessions_count',
                         'trial_price','package_enabled','package_size','package_price'];
begin
  if auth.uid() is null or is_admin() or coalesce(current_setting('classi.bypass_review', true), '') = 'on' then return new; end if;
  if tg_op = 'INSERT' then
    new.review_status := 'pending';
    new.review_note := null;
    new.pending_changes := null;
    perform notify_admins(format('عرض جديد بانتظار المراجعة: %s', new.title));
    return new;
  end if;
  if new.review_status is distinct from old.review_status and not (old.review_status = 'rejected' and new.review_status = 'pending') then
    new.review_status := old.review_status;
  end if;
  new.review_note := old.review_note;
  if old.review_status <> 'approved' then
    if row(new.title, new.subject_id, new.level_id, new.places, new.schedule_note, new.trial_price, new.package_enabled, new.package_size, new.package_price)
       is distinct from row(old.title, old.subject_id, old.level_id, old.places, old.schedule_note, old.trial_price, old.package_enabled, old.package_size, old.package_price) then
      new.review_status := 'pending';
      if old.review_status = 'rejected' then perform notify_admins(format('عرض عُدّل بعد الرفض: %s', new.title)); end if;
    end if;
    return new;
  end if;
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

-- Changing the length of a group/course updates its future meetings.
create or replace function public.offerings_minutes_follow() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.minutes is distinct from old.minutes and new.type in ('group','course') and new.minutes > 0 then
    update sessions set minutes = new.minutes where offering_id = new.id and starts_at > now() and not cancelled;
  end if;
  return new;
end $$;
drop trigger if exists offerings_minutes_follow on public.offerings;
create trigger offerings_minutes_follow after update of minutes on public.offerings
  for each row execute function public.offerings_minutes_follow();

-- ================= 3. course installments =================
alter table public.bookings add column if not exists installments_total int not null default 1 check (installments_total between 1 and 12);
alter table public.bookings add column if not exists installments_paid int not null default 0 check (installments_paid >= 0);
create or replace function public.bookings_installments() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' and new.pay_method = 'installments' then new.installments_total := 3; end if;
  return new;
end $$;
drop trigger if exists bookings_installments on public.bookings;
create trigger bookings_installments before insert on public.bookings for each row execute function public.bookings_installments();
update public.bookings set installments_total = 3 where pay_method = 'installments' and installments_total = 1;

create or replace function public.installment_amount(p_price int, p_total int, p_paid int) returns int
language sql immutable as $$
  -- the last installment absorbs rounding so the total is exact
  select case when p_total <= 1 then p_price
              when p_paid >= p_total - 1 then p_price - (p_price / p_total) * (p_total - 1)
              else p_price / p_total end
$$;

create or replace function public.confirm_payment(p_booking uuid default null, p_package uuid default null, p_received boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare v_off uuid; v_user uuid; v_amount int; v_title text; v_was text; v_total int; v_paid int; v_this int;
begin
  if p_booking is not null then
    select offering_id, booked_by, price, pay_status, installments_total, installments_paid
      into v_off, v_user, v_amount, v_was, v_total, v_paid from bookings where id = p_booking;
  else
    select offering_id, user_id, price, pay_status, 1, 0 into v_off, v_user, v_amount, v_was, v_total, v_paid from lesson_packages where id = p_package;
  end if;
  if v_off is null or not is_offering_owner(v_off) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  if v_was not in ('unpaid','reported','paid') then raise exception 'هذه الحصة لا تحتاج دفعاً (مجانية أو ضمن رزمة)'; end if;
  select title into v_title from offerings where id = v_off;

  if p_booking is not null and v_total > 1 then
    v_this := installment_amount(v_amount, v_total, v_paid);
    if p_received then
      if v_paid >= v_total then raise exception 'كل الدفعات مستلمة'; end if;
      update bookings set installments_paid = installments_paid + 1,
             pay_status = case when installments_paid + 1 >= installments_total then 'paid' else 'unpaid' end,
             paid_at = case when installments_paid + 1 >= installments_total then now() else paid_at end,
             reported_at = null
       where id = p_booking;
    else
      update bookings set pay_status = 'unpaid', reported_at = null where id = p_booking;
    end if;
    if v_was = 'reported' or p_received then
      insert into notifications (user_id, kind, body, link) values (v_user, 'payment_answer',
        case when p_received then format('استلمنا الدفعة %s من %s (%s ₪): %s.%s', v_paid + 1, v_total, v_this, v_title,
                                         case when v_paid + 1 >= v_total then ' تم دفع الدورة كاملة، شكراً!' else '' end)
             else format('لم تصل الدفعة %s من %s (%s ₪) بعد: %s.', v_paid + 1, v_total, v_this, v_title) end,
        '/schedule');
    end if;
    return;
  end if;

  if p_booking is not null then
    update bookings set pay_status = case when p_received then 'paid' else 'unpaid' end,
                        paid_at = case when p_received then now() end,
                        reported_at = case when p_received then reported_at end
     where id = p_booking;
  else
    update lesson_packages set pay_status = case when p_received then 'paid' else 'unpaid' end,
                               paid_at = case when p_received then now() end,
                               reported_at = case when p_received then reported_at end
     where id = p_package;
  end if;
  if v_was = 'reported' then
    insert into notifications (user_id, kind, body, link) values (v_user, 'payment_answer',
      case when p_received then format('أكّد المعلم استلام %s ₪: %s. شكراً!', v_amount, v_title)
           else format('لم يصل تحويل %s ₪ للمعلم بعد: %s. تأكد من رقم Bit وحاول مرة أخرى.', v_amount, v_title) end,
      '/schedule');
  end if;
end $$;

-- The money list shows installments (amount of the next one) and walk-in names.
drop function if exists public.owner_payments();
create or replace function public.owner_payments()
returns table (kind text, id uuid, offering_id uuid, title text, who text, amount int, pay_method text, pay_status text, lesson_at timestamptz,
               reported_at timestamptz, installments_total int, installments_paid int)
language sql stable security definer set search_path = public as $$
  select 'booking', b.id, o.id, o.title, coalesce(c.name, b.offline_name, p.full_name, 'طالب'),
         installment_amount(b.price, b.installments_total, b.installments_paid), b.pay_method, b.pay_status,
         coalesce(b.starts_at, s.starts_at), b.reported_at, b.installments_total, b.installments_paid
    from bookings b join offerings o on o.id = b.offering_id
    left join sessions s on s.id = b.session_id
    left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
   where is_offering_owner(o.id) and b.status = 'confirmed'
     and (b.pay_status = 'reported' or (b.pay_status = 'unpaid' and coalesce(b.starts_at, s.starts_at, b.created_at) <= now() + interval '1 day'))
  union all
  select 'package', k.id, o.id, o.title || ' · رزمة ' || k.size || ' حصص', coalesce(c.name, p.full_name, 'طالب'), k.price, k.pay_method, k.pay_status,
         k.created_at, k.reported_at, 1, 0
    from lesson_packages k join offerings o on o.id = k.offering_id
    left join children c on c.id = k.child_id left join profiles p on p.id = k.user_id
   where is_offering_owner(o.id) and k.status <> 'cancelled' and k.pay_status in ('unpaid','reported')
  order by 8 desc, 9 desc
$$;

-- ================= 4. vacation =================
alter table public.teacher_blocks drop constraint if exists teacher_blocks_minutes_check;
alter table public.teacher_blocks add constraint teacher_blocks_minutes_check check (minutes between 15 and 1440);

create or replace function public.teacher_vacation(p_from date, p_to date, p_note text default null) returns int
language plpgsql security definer set search_path = public as $$
declare v_t uuid := my_teacher_id(); d date; v_at timestamptz; v_n int := 0; v_clash timestamptz;
begin
  if v_t is null then raise exception 'هذه الصفحة للمعلمين'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'اختر تاريخ البداية والنهاية'; end if;
  if p_from < (now() at time zone 'Asia/Jerusalem')::date then raise exception 'اختر أياماً قادمة'; end if;
  if p_to - p_from > 60 then raise exception 'العطلة حتى 60 يوماً في المرة'; end if;
  -- Lessons or meetings inside the vacation must be moved or cancelled first.
  select min(x.s) into v_clash from (
    select b.starts_at s from bookings b join offerings o on o.id = b.offering_id
     where o.teacher_id = v_t and b.status in ('pending','confirmed') and b.starts_at is not null
       and (b.starts_at at time zone 'Asia/Jerusalem')::date between p_from and p_to
    union all
    select se.starts_at from sessions se join offerings o on o.id = se.offering_id
     where (o.teacher_id = v_t or o.course_teacher_id = v_t) and not se.cancelled
       and (se.starts_at at time zone 'Asia/Jerusalem')::date between p_from and p_to) x;
  if v_clash is not null then
    raise exception 'لديك حصة أو لقاء يوم %. غيّر موعده أو ألغِه أولاً، ثم أغلق الأيام.', fmt_time(v_clash);
  end if;
  d := p_from;
  while d <= p_to loop
    v_at := (d + time '00:00') at time zone 'Asia/Jerusalem';
    delete from teacher_blocks where teacher_id = v_t and starts_at >= v_at and starts_at < v_at + interval '1 day';
    insert into teacher_blocks (teacher_id, starts_at, minutes, note) values (v_t, v_at, 1440, coalesce(nullif(trim(p_note), ''), 'عطلة'));
    v_n := v_n + 1;
    d := d + 1;
  end loop;
  return v_n;
end $$;

-- ================= 5. institutes: walk-in students, staff =================

-- Enroll a student who registered at the institute. If the phone belongs to a Classi account,
-- the booking is theirs (they see it in their schedule); otherwise it is kept under the name.
create or replace function public.institute_enroll(p_offering uuid, p_name text, p_phone text default null, p_pay text default 'cash', p_paid boolean default false)
returns uuid
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_phone text := clean_phone(p_phone); v_user uuid; v_id uuid; v_name text := nullif(trim(p_name), '');
begin
  select * into o from offerings where id = p_offering;
  if not found or not is_offering_owner(o.id) then raise exception 'لا تملك صلاحية على هذه الدورة'; end if;
  if o.type <> 'course' then raise exception 'التسجيل اليدوي متاح للدورات'; end if;
  if v_name is null then raise exception 'اكتب اسم الطالب'; end if;
  if nullif(trim(coalesce(p_phone, '')), '') is not null and v_phone is null then raise exception 'رقم الهاتف غير صحيح'; end if;
  if p_pay not in ('cash','bit','installments') then raise exception 'طريقة دفع غير معروفة'; end if;
  if o.type = 'course' and o.seats is not null and seats_taken(o.id) >= o.seats then
    raise exception 'الدورة ممتلئة (% من % مقاعد). زِد عدد المقاعد أولاً.', seats_taken(o.id), o.seats;
  end if;
  if v_phone is not null then select id into v_user from profiles where phone = v_phone limit 1; end if;
  insert into bookings (offering_id, booked_by, minutes, status, pay_method, mode, price, offline_name, offline_phone)
  values (o.id, v_user, o.minutes, 'confirmed', p_pay, o.places[1], o.price, v_name, v_phone)
  returning id into v_id;
  if p_paid then
    update bookings set installments_paid = case when installments_total > 1 then 1 else installments_total end,
           pay_status = case when installments_total > 1 then 'unpaid' else 'paid' end,
           paid_at = case when installments_total > 1 then null else now() end
     where id = v_id;
  end if;
  if v_user is not null then
    insert into notifications (user_id, kind, body, link)
    values (v_user, 'booking_answer', format('سجّلك المعهد في %s باسم %s. تجد المواعيد في جدولك.', o.title, v_name), '/schedule');
  end if;
  return v_id;
end $$;

-- Remove a teacher from the institute's staff: they stop teaching its courses and lose access.
create or replace function public.institute_remove_staff(p_teacher uuid) returns int
language plpgsql security definer set search_path = public as $$
declare v_inst uuid; v_n int; v_user uuid; v_inst_name text;
begin
  select id, name into v_inst, v_inst_name from institutes where owner_id = auth.uid() limit 1;
  if v_inst is null then raise exception 'هذه الصفحة لأصحاب المعاهد'; end if;
  update offerings set course_teacher_id = null where institute_id = v_inst and course_teacher_id = p_teacher;
  get diagnostics v_n = row_count;
  delete from institute_teachers where institute_id = v_inst and teacher_id = p_teacher;
  if not found then raise exception 'المعلم ليس ضمن طاقم المعهد'; end if;
  select user_id into v_user from teachers where id = p_teacher;
  insert into notifications (user_id, kind, body, link)
  values (v_user, 'schedule_changed', format('لم تعد ضمن طاقم %s.', v_inst_name), '/teach');
  return v_n;
end $$;

-- Rosters and meeting lists show walk-in names.
drop function if exists public.owner_bookings(uuid);
create or replace function public.owner_bookings(p_offering uuid default null)
returns table (
  booking_id uuid, offering_id uuid, offering_title text, offering_type public.offering_type,
  student_name text, starts_at timestamptz, session_id uuid, status public.booking_status,
  pay_method text, created_at timestamptz, mode public.place_kind, weekly boolean, series_id uuid, series_count int,
  price int, pay_status text, installments_total int, installments_paid int, offline boolean, offline_phone text)
language sql stable security definer set search_path = public as $$
  select b.id, o.id, o.title, o.type,
         coalesce(c.name, b.offline_name, p.full_name, 'طالب'), coalesce(b.starts_at, s.starts_at), b.session_id,
         b.status, b.pay_method, b.created_at, b.mode, b.weekly, b.series_id,
         case when b.series_id is null then null
              else (select count(*)::int from bookings x where x.series_id = b.series_id and x.status in ('pending','confirmed')) end,
         b.price, b.pay_status, b.installments_total, b.installments_paid, b.booked_by is null, b.offline_phone
  from bookings b
  join offerings o on o.id = b.offering_id
  left join children c on c.id = b.child_id
  left join profiles p on p.id = b.booked_by
  left join sessions s on s.id = b.session_id
  where is_offering_staff(o.id) and (p_offering is null or o.id = p_offering)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;

create or replace function public.session_students(p_session uuid)
returns table (booking_id uuid, who text, report_id uuid, present boolean, understanding smallint, participation smallint, note text, summary text, homework text)
language sql stable security definer set search_path = public as $$
  select x.id, coalesce(c.name, x.offline_name, p.full_name, 'طالب'), r.id, coalesce(r.present, true), r.understanding, r.participation, r.note, r.summary, r.homework
    from sessions s join offerings o on o.id = s.offering_id
    join bookings x on x.status = 'confirmed' and (x.session_id = s.id or (o.type = 'course' and x.offering_id = o.id and x.session_id is null))
    left join children c on c.id = x.child_id left join profiles p on p.id = x.booked_by
    left join lesson_reports r on r.booking_id = x.id and r.session_id is not distinct from case when o.type = 'course' then s.id else x.session_id end
   where s.id = p_session and is_offering_staff(o.id)
   order by 2
$$;

revoke execute on function public.extend_group_sessions from anon, authenticated, public;
revoke execute on function public.cancel_session, public.teacher_vacation, public.institute_enroll, public.institute_remove_staff, public.owner_payments from anon, public;
grant execute on function public.cancel_session, public.teacher_vacation, public.institute_enroll, public.institute_remove_staff, public.owner_payments, public.owner_bookings, public.session_students to authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'classi-group-sessions';
    perform cron.schedule('classi-group-sessions', '17 3 * * *', 'select public.extend_group_sessions()');
  end if;
end $$;
-- Fill the gap right away for groups created more than a few weeks ago.
select public.extend_group_sessions();


-- Whole-day closures (vacation) start at midnight: look back a full day when checking clashes.
create or replace function public.teacher_busy(p_teacher uuid, p_from timestamptz, p_to timestamptz)
returns table (starts_at timestamptz, minutes int)
language sql stable security definer set search_path = public as $$
  select b.starts_at, b.minutes
  from bookings b join offerings o on o.id = b.offering_id
  where o.teacher_id = p_teacher and b.status in ('pending','confirmed')
    and b.starts_at between p_from and p_to
  union all
  select s.starts_at, s.minutes
  from sessions s join offerings o on o.id = s.offering_id
  where (o.teacher_id = p_teacher or o.course_teacher_id = p_teacher)
    and not s.cancelled and s.starts_at between p_from and p_to
  union all
  select k.starts_at, k.minutes from teacher_blocks k
  where k.teacher_id = p_teacher and k.starts_at between p_from - interval '1 day' and p_to
$$;

create or replace function public.teacher_clash(
  p_teacher uuid, p_start timestamptz, p_minutes int,
  p_ignore_series uuid default null, p_ignore_booking uuid default null, p_use_buffer boolean default true)
returns boolean
language sql stable security definer set search_path = public as $$
  with buf as (select make_interval(mins => case when p_use_buffer then coalesce((select buffer_minutes from teachers where id = p_teacher), 0) else 0 end) b)
  select exists (
    select 1 from buf, (
      select bk.starts_at s, bk.minutes m from bookings bk join offerings o on o.id = bk.offering_id
       where o.teacher_id = p_teacher and bk.status in ('pending','confirmed') and bk.starts_at is not null
         and (p_ignore_series is null or bk.series_id is distinct from p_ignore_series)
         and (p_ignore_booking is null or bk.id <> p_ignore_booking)
         and bk.starts_at between p_start - interval '10 hours' and p_start + interval '10 hours'
      union all
      select se.starts_at, se.minutes from sessions se join offerings o on o.id = se.offering_id
       where (o.teacher_id = p_teacher or o.course_teacher_id = p_teacher) and not se.cancelled
         and se.starts_at between p_start - interval '10 hours' and p_start + interval '10 hours'
      union all
      select k.starts_at, k.minutes from teacher_blocks k
       where k.teacher_id = p_teacher and k.starts_at between p_start - interval '1 day' and p_start + interval '10 hours'
    ) busy
    where tstzrange(busy.s - buf.b, busy.s + make_interval(mins => busy.m) + buf.b)
       && tstzrange(p_start, p_start + make_interval(mins => p_minutes))
  )
$$;

-- "I transferred" for a course installment reports the installment's amount.
create or replace function public.report_payment(p_booking uuid default null, p_package uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_off uuid; v_amount int; v_who text; v_title text; v_owner uuid; v_when text; v_part text;
begin
  if p_booking is not null then
    update bookings set pay_status = 'reported', reported_at = now()
     where id = p_booking and booked_by = auth.uid() and pay_status = 'unpaid' and status in ('pending','confirmed')
     returning offering_id, installment_amount(price, installments_total, installments_paid), fmt_time(starts_at),
               case when installments_total > 1 then format(' (الدفعة %s من %s)', installments_paid + 1, installments_total) end
       into v_off, v_amount, v_when, v_part;
  elsif p_package is not null then
    update lesson_packages set pay_status = 'reported', reported_at = now()
     where id = p_package and user_id = auth.uid() and pay_status = 'unpaid' and status <> 'cancelled'
     returning offering_id, price into v_off, v_amount;
  end if;
  if v_off is null then raise exception 'لا يوجد مبلغ بانتظار الدفع هنا'; end if;
  select title into v_title from offerings where id = v_off;
  select full_name into v_who from profiles where id = auth.uid();
  v_owner := offering_owner_user(v_off);
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (v_owner, 'payment_reported',
      format('أبلغ %s عن تحويل %s ₪ عبر Bit: %s%s%s. تأكد من وصول المبلغ.', coalesce(v_who, 'طالب'), v_amount, v_title, coalesce(v_part, ''),
             case when p_package is not null then ' (رزمة حصص)' else coalesce('، حصة ' || v_when, '') end),
      '/teach#payments');
  end if;
end $$;
