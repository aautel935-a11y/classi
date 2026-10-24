-- Classi: a report for the parent after every lesson.
-- The teacher (or the institute's course teacher) writes what was covered, the homework,
-- how well the student understood and took part, and a note. The parent is notified right away.
-- Group and course meetings: one shared summary and homework, plus a line per student.

create table if not exists public.lesson_reports (
  id            uuid primary key default gen_random_uuid(),
  booking_id    uuid not null references public.bookings(id) on delete cascade,
  session_id    uuid references public.sessions(id) on delete cascade,  -- the meeting, for groups and courses
  offering_id   uuid not null references public.offerings(id) on delete cascade,
  student_user  uuid not null references public.profiles(id) on delete cascade, -- who booked (parent or student)
  child_id      uuid references public.children(id) on delete set null,
  author_id     uuid not null references public.profiles(id) on delete cascade,
  lesson_at     timestamptz not null,
  present       boolean not null default true,
  summary       text check (char_length(summary) <= 2000),
  homework      text check (char_length(homework) <= 1000),
  understanding smallint check (understanding between 1 and 5),
  participation smallint check (participation between 1 and 5),
  note          text check (char_length(note) <= 1000),
  read_at       timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index if not exists lesson_reports_one
  on public.lesson_reports (booking_id, coalesce(session_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index if not exists lesson_reports_parent on public.lesson_reports (student_user, lesson_at desc);

alter table public.lesson_reports enable row level security;
create policy "parent or staff reads reports" on public.lesson_reports for select
  using (student_user = auth.uid() or is_offering_staff(offering_id) or is_admin());
grant select on public.lesson_reports to authenticated;

-- One lesson occurrence a report can be written for: private booking, group booking, or a course meeting.
create or replace function public.report_target(p_booking uuid, p_session uuid default null)
returns table (booking_id uuid, session_id uuid, offering_id uuid, student_user uuid, child_id uuid, lesson_at timestamptz, title text, who text)
language sql stable security definer set search_path = public as $$
  select b.id, coalesce(b.session_id, s.id), o.id, b.booked_by, b.child_id,
         coalesce(b.starts_at, bs.starts_at, s.starts_at), o.title, coalesce(c.name, p.full_name, 'الطالب')
    from bookings b join offerings o on o.id = b.offering_id
    left join sessions bs on bs.id = b.session_id
    left join sessions s on s.id = p_session and s.offering_id = o.id and o.type = 'course' and b.session_id is null
    left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
   where b.id = p_booking and b.status = 'confirmed'
     and (o.type <> 'course' or s.id is not null)
$$;

-- Write or update one student's report. Returns the report id.
create or replace function public.write_lesson_report(
  p_booking uuid, p_session uuid default null, p_summary text default null, p_homework text default null,
  p_understanding int default null, p_participation int default null, p_note text default null, p_present boolean default true)
returns uuid
language plpgsql security definer set search_path = public as $$
declare t record; v_id uuid; v_new boolean;
begin
  select * into t from report_target(p_booking, p_session);
  if not found then raise exception 'الحصة غير موجودة أو غير مؤكدة'; end if;
  if not is_offering_staff(t.offering_id) then raise exception 'التقرير يكتبه معلم الحصة فقط'; end if;
  if t.lesson_at > now() + interval '15 minutes' then raise exception 'يُكتب التقرير بعد بدء الحصة'; end if;
  if p_present and coalesce(trim(p_summary), '') = '' and coalesce(trim(p_note), '') = '' and p_understanding is null then
    raise exception 'اكتب ملخصاً أو ملاحظة على الأقل';
  end if;

  select id into v_id from lesson_reports
   where booking_id = t.booking_id and session_id is not distinct from t.session_id;
  v_new := v_id is null;
  if v_new then
    insert into lesson_reports (booking_id, session_id, offering_id, student_user, child_id, author_id, lesson_at, present,
                                summary, homework, understanding, participation, note)
    values (t.booking_id, t.session_id, t.offering_id, t.student_user, t.child_id, auth.uid(), t.lesson_at, p_present,
            nullif(trim(p_summary), ''), nullif(trim(p_homework), ''), p_understanding, p_participation, nullif(trim(p_note), ''))
    returning id into v_id;
  else
    update lesson_reports set present = p_present, summary = nullif(trim(p_summary), ''), homework = nullif(trim(p_homework), ''),
           understanding = p_understanding, participation = p_participation, note = nullif(trim(p_note), ''),
           author_id = auth.uid(), updated_at = now(), read_at = null
     where id = v_id;
  end if;

  -- Courses keep their attendance list in step.
  if t.session_id is not null then
    insert into attendance (session_id, booking_id, present) values (t.session_id, t.booking_id, p_present)
    on conflict (session_id, booking_id) do update set present = excluded.present;
  end if;

  insert into notifications (user_id, kind, body, link) values (
    t.student_user, 'lesson_report',
    case when not p_present then format('%s: سُجّل غياب %s عن حصة %s.', t.title, t.who, fmt_time(t.lesson_at))
         when v_new then format('تقرير حصة %s لـ%s جاهز%s.', t.title, t.who,
                                coalesce(': ' || left(nullif(trim(p_summary), ''), 60) || case when length(trim(p_summary)) > 60 then '…' else '' end, ''))
         else format('حدّث المعلم تقرير حصة %s لـ%s.', t.title, t.who) end,
    '/reports/' || v_id);
  return v_id;
end $$;

-- Group or course meeting: shared summary and homework, a line per student.
-- p_items: [{"booking_id": "...", "present": true, "understanding": 4, "participation": 5, "note": "..."}]
create or replace function public.write_session_reports(p_session uuid, p_summary text, p_homework text, p_items jsonb)
returns int
language plpgsql security definer set search_path = public as $$
declare s sessions%rowtype; o offerings%rowtype; it jsonb; v_n int := 0;
begin
  select * into s from sessions where id = p_session;
  if not found then raise exception 'اللقاء غير موجود'; end if;
  select * into o from offerings where id = s.offering_id;
  if not is_offering_staff(o.id) then raise exception 'التقرير يكتبه معلم اللقاء فقط'; end if;
  if coalesce(trim(p_summary), '') = '' then raise exception 'اكتب ملخص اللقاء'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    perform write_lesson_report(
      (it->>'booking_id')::uuid, case when o.type = 'course' then p_session end, p_summary, p_homework,
      nullif(it->>'understanding', '')::int, nullif(it->>'participation', '')::int, it->>'note',
      coalesce((it->>'present')::boolean, true));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.mark_report_read(p_report uuid) returns void
language sql security definer set search_path = public as $$
  update lesson_reports set read_at = coalesce(read_at, now()) where id = p_report and student_user = auth.uid()
$$;

-- Lessons of the last two weeks still waiting for the teacher's report.
create or replace function public.pending_reports()
returns table (booking_id uuid, session_id uuid, offering_id uuid, title text, who text, lesson_at timestamptz, kind text, students int)
language sql stable security definer set search_path = public as $$
  with me as (select my_teacher_id() t)
  -- private lessons
  select b.id, null::uuid, o.id, o.title, coalesce(c.name, p.full_name, 'طالب'), b.starts_at, 'private', 1
    from bookings b join offerings o on o.id = b.offering_id join me on o.teacher_id = me.t
    left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
   where o.type = 'private' and b.status = 'confirmed'
     and b.starts_at between now() - interval '14 days' and now()
     and not exists (select 1 from lesson_reports r where r.booking_id = b.id)
  union all
  -- group and course meetings with at least one student not reported yet
  select null, s.id, o.id, o.title, null, s.starts_at, o.type::text,
         (select count(*)::int from bookings x where x.status = 'confirmed'
            and (x.session_id = s.id or (o.type = 'course' and x.offering_id = o.id and x.session_id is null)))
    from sessions s join offerings o on o.id = s.offering_id join me on (o.teacher_id = me.t or o.course_teacher_id = me.t)
   where not s.cancelled and s.starts_at between now() - interval '14 days' and now()
     and exists (select 1 from bookings x where x.status = 'confirmed'
                   and (x.session_id = s.id or (o.type = 'course' and x.offering_id = o.id and x.session_id is null))
                   and not exists (select 1 from lesson_reports r where r.booking_id = x.id
                                     and r.session_id is not distinct from case when o.type = 'course' then s.id else x.session_id end))
  order by 6 desc
$$;

-- Students of a meeting, with any report already written, for the meeting form.
create or replace function public.session_students(p_session uuid)
returns table (booking_id uuid, who text, report_id uuid, present boolean, understanding smallint, participation smallint, note text, summary text, homework text)
language sql stable security definer set search_path = public as $$
  select x.id, coalesce(c.name, p.full_name, 'طالب'), r.id, coalesce(r.present, true), r.understanding, r.participation, r.note, r.summary, r.homework
    from sessions s join offerings o on o.id = s.offering_id
    join bookings x on x.status = 'confirmed' and (x.session_id = s.id or (o.type = 'course' and x.offering_id = o.id and x.session_id is null))
    left join children c on c.id = x.child_id left join profiles p on p.id = x.booked_by
    left join lesson_reports r on r.booking_id = x.id and r.session_id is not distinct from case when o.type = 'course' then s.id else x.session_id end
   where s.id = p_session and is_offering_staff(o.id)
   order by 2
$$;

-- The parent's reports, newest first.
create or replace function public.my_reports(p_child uuid default null, p_limit int default 50)
returns table (id uuid, offering_id uuid, title text, teacher text, child_id uuid, child_name text, lesson_at timestamptz,
               present boolean, summary text, homework text, understanding smallint, participation smallint, note text, read_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.id, o.id, o.title, coalesce(t.name, i.name), r.child_id, c.name, r.lesson_at, r.present, r.summary, r.homework,
         r.understanding, r.participation, r.note, r.read_at
    from lesson_reports r join offerings o on o.id = r.offering_id
    left join teachers t on t.id = coalesce(o.course_teacher_id, o.teacher_id)
    left join institutes i on i.id = o.institute_id
    left join children c on c.id = r.child_id
   where r.student_user = auth.uid() and (p_child is null or r.child_id = p_child)
   order by r.lesson_at desc
   limit least(greatest(p_limit, 1), 200)
$$;

-- Nudge teachers 30 minutes after a lesson ends if the report is not written yet.
create or replace function public.report_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0; v_key text;
begin
  for r in
    select 'b' || b.id::text ref, t.user_id, o.title, coalesce(c.name, p.full_name, 'الطالب') who, b.id booking_id, null::uuid session_id
      from bookings b join offerings o on o.id = b.offering_id join teachers t on t.id = o.teacher_id
      left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
     where o.type = 'private' and b.status = 'confirmed' and t.user_id is not null
       and b.starts_at + make_interval(mins => b.minutes + 30) between now() - interval '3 hours' and now()
       and not exists (select 1 from lesson_reports x where x.booking_id = b.id)
    union all
    select 'm' || s.id::text, t.user_id, o.title, null, null, s.id
      from sessions s join offerings o on o.id = s.offering_id join teachers t on t.id = coalesce(o.course_teacher_id, o.teacher_id)
     where not s.cancelled and t.user_id is not null
       and s.starts_at + make_interval(mins => s.minutes + 30) between now() - interval '3 hours' and now()
       and exists (select 1 from bookings x where x.status = 'confirmed' and (x.session_id = s.id or (o.type = 'course' and x.offering_id = o.id and x.session_id is null)))
       and not exists (select 1 from lesson_reports x where x.session_id = s.id)
  loop
    v_key := format('rep:%s', r.ref);
    insert into reminder_log (key) values (v_key) on conflict do nothing;
    if not found then continue; end if;
    insert into notifications (user_id, kind, body, link) values (r.user_id, 'report_due',
      case when r.who is not null then format('انتهت حصة %s مع %s. اكتب تقريراً قصيراً لولي الأمر.', r.title, r.who)
           else format('انتهى لقاء %s. اكتب تقرير اللقاء للطلاب.', r.title) end,
      case when r.booking_id is not null then '/teach/report?booking=' || r.booking_id else '/teach/report?session=' || r.session_id end);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Parents' report notifications and teachers' reminders also go to the phone.
create or replace function public.notifications_mark_push() returns trigger
language plpgsql as $$
begin
  new.want_push := new.kind in ('reminder','reminder_soon','booking_answer','booking_request','booking_new','booking_cancelled',
                                'schedule_changed','waitlist_open','waitlist_answer','waitlist_join','verified','message',
                                'lesson_report','report_due');
  return new;
end $$;

revoke execute on function public.report_target, public.write_lesson_report, public.write_session_reports, public.mark_report_read,
  public.pending_reports, public.session_students, public.my_reports, public.report_reminders from anon, public;
grant execute on function public.write_lesson_report, public.write_session_reports, public.mark_report_read,
  public.pending_reports, public.session_students, public.my_reports to authenticated;
revoke execute on function public.report_reminders from authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'classi-report-reminders';
    perform cron.schedule('classi-report-reminders', '*/10 * * * *', 'select public.report_reminders()');
  end if;
end $$;

-- ================= phone number (for SMS / WhatsApp reminders later) =================
alter table public.profiles add column if not exists sms_ok boolean not null default true;
create or replace function public.clean_phone(p text) returns text
language sql immutable as $$
  select case when regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g') ~ '^(\+?972|0)5[0-9]{8}$'
              then regexp_replace(regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g'), '^(\+?972|0)', '+972')
              else null end
$$;
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_role app_role;
begin
  v_role := case when new.raw_user_meta_data->>'role' in ('guardian','student','teacher','institute')
                 then (new.raw_user_meta_data->>'role')::app_role else 'guardian' end;
  insert into profiles (id, full_name, phone, town, roles, active_role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''), coalesce(new.phone, clean_phone(new.raw_user_meta_data->>'phone')),
          nullif(new.raw_user_meta_data->>'town', ''), array[v_role], v_role)
  on conflict (id) do nothing;
  return new;
end $$;
