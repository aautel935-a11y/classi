-- Classi: same-day SMS reminders.
--  · student / parent: one SMS 4 hours before each lesson (the day-before reminder stays free: in-app, push, email)
--  · teacher: one SMS per day, 4 hours before the first lesson, listing the day's lessons
-- Also: direct admin notes and admin title edits now reach the phone (push), which they did not before.

create or replace function public.sms_kinds() returns text[] language sql immutable as $$
  select array['reminder_today','schedule_changed','booking_cancelled','admin_note']
$$;

create or replace function public.notifications_mark_push() returns trigger
language plpgsql as $$
begin
  new.want_push := new.kind in ('reminder','reminder_today','reminder_soon','booking_answer','booking_request','booking_new','booking_cancelled',
                                'schedule_changed','waitlist_open','waitlist_answer','waitlist_join','verified','message',
                                'lesson_report','report_due','payment_reported','payment_answer','review_needed','review_answer',
                                'subscription','review_new','review_prompt','admin_note','review');
  return new;
end $$;

create or replace function public.send_today_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0; v_key text; v_today date := (now() at time zone 'Asia/Jerusalem')::date; v_list text; v_more int;
begin
  -- Student side: lessons 2–4 hours from now (later bookings get only the 1-hour notification).
  for r in
    with occ as (
      select b.id booking_id, null::uuid session_id, b.starts_at, b.booked_by, b.child_id, b.offering_id, b.mode
        from bookings b where b.status = 'confirmed' and b.starts_at is not null
         and b.starts_at > now() + interval '2 hours' and b.starts_at <= now() + interval '4 hours'
      union all
      select b.id, s.id, s.starts_at, b.booked_by, b.child_id, b.offering_id, b.mode
        from bookings b join sessions s on s.id = b.session_id
       where b.status = 'confirmed' and not s.cancelled
         and s.starts_at > now() + interval '2 hours' and s.starts_at <= now() + interval '4 hours'
      union all
      select b.id, s.id, s.starts_at, b.booked_by, b.child_id, b.offering_id, b.mode
        from bookings b join offerings o on o.id = b.offering_id and o.type = 'course'
        join sessions s on s.offering_id = o.id
       where b.status = 'confirmed' and b.session_id is null and not s.cancelled
         and s.starts_at > now() + interval '2 hours' and s.starts_at <= now() + interval '4 hours'
    )
    select occ.*, o.title, coalesce(t.name, i.name) owner_name, c.name child_name, rm.name room
      from occ join offerings o on o.id = occ.offering_id
      left join teachers t on t.id = coalesce(o.course_teacher_id, o.teacher_id)
      left join institutes i on i.id = o.institute_id
      left join children c on c.id = occ.child_id
      left join sessions s2 on s2.id = occ.session_id
      left join rooms rm on rm.id = s2.room_id
     where occ.booked_by is not null and is_active_user(occ.booked_by)
  loop
    v_key := format('s:%s:%s:today', r.booking_id, coalesce(r.session_id::text, '-'));
    insert into reminder_log (key) values (v_key) on conflict do nothing;
    if not found then continue; end if;
    insert into notifications (user_id, kind, body, link) values (
      r.booked_by, 'reminder_today',
      format('تذكير: اليوم الساعة %s %s مع %s%s%s%s', hhmm(r.starts_at), r.title, r.owner_name,
             coalesce(' لـ' || r.child_name, ''), coalesce('، ' || r.room, ''),
             case when r.mode = 'online' then '، أونلاين (الرابط في جدولك).' else '.' end),
      '/schedule');
    v_n := v_n + 1;
  end loop;

  -- Teacher side: once a day, when the first remaining lesson of today is within 4 hours.
  for r in
    with occ as (
      select t.user_id, b.starts_at, coalesce(c.name, p.full_name, b.offline_name, 'طالب') who, o.title
        from bookings b join offerings o on o.id = b.offering_id and o.type = 'private'
        join teachers t on t.id = o.teacher_id
        left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
       where b.status = 'confirmed' and b.starts_at > now() and (b.starts_at at time zone 'Asia/Jerusalem')::date = v_today
      union all
      select t.user_id, s.starts_at,
             (select count(*)::text from bookings b where b.status = 'confirmed'
                and ((o.type = 'group' and b.session_id = s.id) or (o.type = 'course' and b.offering_id = o.id and b.session_id is null))) || ' طلاب',
             o.title
        from sessions s join offerings o on o.id = s.offering_id
        join teachers t on t.id = coalesce(o.course_teacher_id, o.teacher_id)
       where not s.cancelled and s.starts_at > now() and (s.starts_at at time zone 'Asia/Jerusalem')::date = v_today
         and exists (select 1 from bookings b where b.status = 'confirmed'
                       and ((o.type = 'group' and b.session_id = s.id) or (o.type = 'course' and b.offering_id = o.id and b.session_id is null)))
    )
    select user_id, min(starts_at) first_at, count(*) n,
           array_agg(hhmm(starts_at) || ' ' || who order by starts_at) items
      from occ where user_id is not null and is_active_user(user_id)
     group by user_id
    having min(starts_at) <= now() + interval '4 hours'
  loop
    v_key := format('td:%s:%s', r.user_id, v_today);
    insert into reminder_log (key) values (v_key) on conflict do nothing;
    if not found then continue; end if;
    v_more := greatest(r.n - 5, 0);
    v_list := array_to_string(r.items[1:5], '، ') || case when v_more > 0 then format(' و%s أخرى', v_more) else '' end;
    insert into notifications (user_id, kind, body, link) values (
      r.user_id, 'reminder_today',
      format('حصصك اليوم (%s): %s. التفاصيل في تقويمك.', r.n, v_list),
      '/teach/calendar');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function public.send_today_reminders from anon, authenticated, public;

-- Runs with the other reminders every 5 minutes.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'classi-today';
    perform cron.schedule('classi-today', '*/5 * * * *', 'select public.send_today_reminders()');
  end if;
end $$;
