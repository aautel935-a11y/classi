-- Classi: launch hardening.
--  1. two people booking the same hour at the same second: bookings for one teacher are checked one at a time
--  2. two people taking the last seat at the same second: seats re-counted under a lock after insert
--  3. cancelling a course meeting can add a make-up meeting at the end
--  4. a walk-in parent who later joins Classi with the same phone: the institute is told and links with one tap

-- ================= 1. one booking check at a time per teacher =================
-- Every booking path calls teacher_clash() before inserting. Taking a transaction lock here makes a second
-- booking for the same teacher wait until the first commits, and then see it.
create or replace function public.teacher_clash(
  p_teacher uuid, p_start timestamptz, p_minutes int,
  p_ignore_series uuid default null, p_ignore_booking uuid default null, p_use_buffer boolean default true)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare v_buf interval; v_hit boolean;
begin
  perform pg_advisory_xact_lock(hashtext('teacher:' || p_teacher::text));
  v_buf := make_interval(mins => case when p_use_buffer then coalesce((select buffer_minutes from teachers where id = p_teacher), 0) else 0 end);
  select exists (
    select 1 from (
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
    where tstzrange(busy.s - v_buf, busy.s + make_interval(mins => busy.m) + v_buf)
       && tstzrange(p_start, p_start + make_interval(mins => p_minutes))
  ) into v_hit;
  return v_hit;
end $$;
revoke execute on function public.teacher_clash from anon, public;
grant execute on function public.teacher_clash to authenticated;

-- ================= 2. last seat =================
create or replace function public.bookings_seat_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_n int;
begin
  if new.status not in ('pending','confirmed') then return null; end if;
  select * into o from offerings where id = new.offering_id;
  if o.seats is null or o.type not in ('course','group') then return null; end if;
  if o.type = 'group' and new.session_id is null then return null; end if;
  -- The owner may add an extra chair on purpose (accepting from the waitlist); the nightly job checks seats itself.
  if auth.uid() is null or is_offering_owner(o.id) then return null; end if;
  perform pg_advisory_xact_lock(hashtext('seats:' || coalesce(new.session_id, new.offering_id)::text));
  select count(*) into v_n from bookings
   where offering_id = o.id and status in ('pending','confirmed')
     and (case when o.type = 'group' then session_id = new.session_id else session_id is null end);
  if v_n > o.seats then raise exception 'نفدت المقاعد قبل لحظات. انضم لقائمة الانتظار وسنبلغك عند فراغ مقعد.'; end if;
  return null;
end $$;
drop trigger if exists bookings_seat_guard on public.bookings;
create trigger bookings_seat_guard after insert on public.bookings
  for each row execute function public.bookings_seat_guard();

-- ================= 3. make-up meeting =================
drop function if exists public.cancel_session(uuid, text);
create or replace function public.cancel_session(p_session uuid, p_reason text default null, p_makeup boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare s sessions%rowtype; o offerings%rowtype; v_n int := 0; v_reason text := nullif(trim(p_reason), '');
        v_course_teacher uuid; v_last sessions%rowtype; v_new timestamptz; v_extra text := '';
begin
  select * into s from sessions where id = p_session;
  if not found then raise exception 'اللقاء غير موجود'; end if;
  select * into o from offerings where id = s.offering_id;
  if not is_offering_owner(o.id) then raise exception 'إلغاء اللقاءات لصاحب العرض فقط'; end if;
  if s.cancelled then raise exception 'اللقاء ملغى سابقاً'; end if;
  if s.starts_at < now() then raise exception 'لا يمكن إلغاء لقاء انتهى'; end if;
  update sessions set cancelled = true where id = s.id;

  update bookings set status = 'cancelled' where session_id = s.id and status in ('pending','confirmed');
  get diagnostics v_n = row_count;

  -- A course has a fixed number of meetings: add one after the last, same weekday, time, room and length.
  if p_makeup and o.type = 'course' then
    select * into v_last from sessions where offering_id = o.id order by starts_at desc limit 1;
    v_new := ((v_last.starts_at at time zone 'Asia/Jerusalem') + interval '7 days') at time zone 'Asia/Jerusalem';
    insert into sessions (offering_id, seq, starts_at, minutes, room_id)
    values (o.id, (select max(seq) + 1 from sessions where offering_id = o.id), v_new, v_last.minutes, v_last.room_id);
    perform set_config('classi.bypass_review', 'on', true);
    update offerings set sessions_count = coalesce(sessions_count, 0) + 1 where id = o.id;
    perform set_config('classi.bypass_review', 'off', true);
    v_extra := format(' أُضيف لقاء تعويضي يوم %s.', fmt_time(v_new));
  end if;

  insert into notifications (user_id, kind, body, link)
  select distinct b.booked_by, 'schedule_changed',
         format('أُلغي لقاء %s يوم %s.%s%s', o.title, fmt_time(s.starts_at), coalesce(' «' || v_reason || '»', ''), v_extra), '/schedule'
    from bookings b
   where (b.session_id = s.id or (o.type = 'course' and b.offering_id = o.id and b.session_id is null and b.status in ('pending','confirmed')))
     and b.booked_by is not null;
  select user_id into v_course_teacher from teachers where id = o.course_teacher_id;
  if v_course_teacher is not null and v_course_teacher <> auth.uid() then
    insert into notifications (user_id, kind, body, link)
    values (v_course_teacher, 'schedule_changed', format('أُلغي لقاء %s يوم %s.%s%s', o.title, fmt_time(s.starts_at), coalesce(' «' || v_reason || '»', ''), v_extra), '/teach');
  end if;
  if o.institute_id is not null then
    insert into change_log (offering_id, changed_by, body, notified_count)
    values (o.id, auth.uid(), format('أُلغي اللقاء %s (%s)%s%s', s.seq, fmt_time(s.starts_at), coalesce(': ' || v_reason, ''), v_extra),
            (select count(distinct booked_by) from bookings where offering_id = o.id and status in ('pending','confirmed')));
  end if;
  return v_n;
end $$;
revoke execute on function public.cancel_session from anon, public;
grant execute on function public.cancel_session to authenticated;

-- ================= 4. walk-in joins Classi later =================
-- Phones are not verified, so linking is the institute's call (they know the parent), never automatic.
drop function if exists public.owner_bookings(uuid);
create or replace function public.owner_bookings(p_offering uuid default null)
returns table (
  booking_id uuid, offering_id uuid, offering_title text, offering_type public.offering_type,
  student_name text, starts_at timestamptz, session_id uuid, status public.booking_status,
  pay_method text, created_at timestamptz, mode public.place_kind, weekly boolean, series_id uuid, series_count int,
  price int, pay_status text, installments_total int, installments_paid int, offline boolean, offline_phone text, can_link boolean)
language sql stable security definer set search_path = public as $$
  select b.id, o.id, o.title, o.type,
         coalesce(c.name, b.offline_name, p.full_name, 'طالب'), coalesce(b.starts_at, s.starts_at), b.session_id,
         b.status, b.pay_method, b.created_at, b.mode, b.weekly, b.series_id,
         case when b.series_id is null then null
              else (select count(*)::int from bookings x where x.series_id = b.series_id and x.status in ('pending','confirmed')) end,
         b.price, b.pay_status, b.installments_total, b.installments_paid, b.booked_by is null, b.offline_phone,
         b.booked_by is null and b.offline_phone is not null and is_offering_owner(o.id)
           and exists (select 1 from profiles pp where pp.phone = b.offline_phone)
  from bookings b
  join offerings o on o.id = b.offering_id
  left join children c on c.id = b.child_id
  left join profiles p on p.id = b.booked_by
  left join sessions s on s.id = b.session_id
  where is_offering_staff(o.id) and (p_offering is null or o.id = p_offering)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;
grant execute on function public.owner_bookings to authenticated;

create or replace function public.institute_link_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_user uuid; v_title text;
begin
  select * into b from bookings where id = p_booking;
  if not found or not is_offering_owner(b.offering_id) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  if b.booked_by is not null then raise exception 'الحجز مربوط بحساب سابقاً'; end if;
  select id into v_user from profiles where phone = b.offline_phone limit 1;
  if v_user is null then raise exception 'لا يوجد حساب في Classi بهذا الرقم بعد'; end if;
  update bookings set booked_by = v_user where id = b.id;
  update lesson_reports set student_user = v_user where booking_id = b.id and student_user is null;
  select title into v_title from offerings where id = b.offering_id;
  insert into notifications (user_id, kind, body, link)
  values (v_user, 'booking_answer', format('ربط المعهد تسجيل %s في %s بحسابك. تجد المواعيد والتقارير والدفعات في جدولك.', b.offline_name, v_title), '/schedule');
end $$;
revoke execute on function public.institute_link_booking from anon, public;
grant execute on function public.institute_link_booking to authenticated;

-- When someone joins (or adds a phone) matching a walk-in, the institute hears about it.
create or replace function public.profiles_walkin_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.phone is null or (tg_op = 'UPDATE' and new.phone is not distinct from old.phone) then return new; end if;
  insert into notifications (user_id, kind, body, link)
  select distinct offering_owner_user(b.offering_id), 'booking_answer',
         format('انضم إلى Classi صاحب الرقم المسجّل للطالب %s (%s). إن كان ولي أمره، اربط الحجز بحسابه من صفحة الدورة.', b.offline_name, o.title),
         '/manage/course/' || o.id
    from bookings b join offerings o on o.id = b.offering_id
   where b.booked_by is null and b.offline_phone = new.phone and b.status in ('pending','confirmed');
  return new;
end $$;
drop trigger if exists profiles_walkin_notice on public.profiles;
create trigger profiles_walkin_notice after insert or update of phone on public.profiles
  for each row execute function public.profiles_walkin_notice();
