-- Classi: the teacher runs their own calendar.
--  · close hours (personal time, a student from outside the app), once or every week
--  · put one of their students into a free hour, once or as a weekly slot
--  · move a booking (this lesson only, or this and every later week of a weekly slot)
--  · cancel a booking with a reason
-- Students are told every time, and a lesson the teacher moved can be cancelled for free.

create table if not exists public.teacher_blocks (
  id         uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  starts_at  timestamptz not null,
  minutes    int not null check (minutes between 15 and 600),
  note       text check (char_length(note) <= 120),
  created_at timestamptz not null default now()
);
create index if not exists teacher_blocks_time on public.teacher_blocks (teacher_id, starts_at);
alter table public.teacher_blocks enable row level security;
create policy "teacher sees own blocks" on public.teacher_blocks for select
  using (exists (select 1 from teachers t where t.id = teacher_id and t.user_id = auth.uid()));
grant select on public.teacher_blocks to authenticated;

alter table public.bookings add column if not exists changed_at timestamptz; -- last time the teacher moved it

-- The teacher's own teacher row.
create or replace function public.my_teacher_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from teachers where user_id = auth.uid() limit 1
$$;

-- Busy times shown to students now include closed hours.
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
  where k.teacher_id = p_teacher and k.starts_at between p_from - interval '10 hours' and p_to
$$;

-- Clash check, now aware of closed hours and able to ignore the booking being moved.
drop function if exists public.teacher_clash(uuid, timestamptz, int, uuid);
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
       where k.teacher_id = p_teacher and k.starts_at between p_start - interval '10 hours' and p_start + interval '10 hours'
    ) busy
    where tstzrange(busy.s - buf.b, busy.s + make_interval(mins => busy.m) + buf.b)
       && tstzrange(p_start, p_start + make_interval(mins => p_minutes))
  )
$$;

-- ================= closing and opening hours =================
create or replace function public.teacher_block(p_starts_at timestamptz, p_minutes int, p_note text default null, p_weeks int default 1)
returns int
language plpgsql security definer set search_path = public as $$
declare v_t uuid := my_teacher_id(); k int; v_at timestamptz; v_n int := 0;
begin
  if v_t is null then raise exception 'هذه الصفحة للمعلمين'; end if;
  if p_starts_at < now() then raise exception 'اختر وقتاً قادماً'; end if;
  if p_weeks not between 1 and 26 then raise exception 'عدد الأسابيع بين 1 و26'; end if;
  for k in 0 .. p_weeks - 1 loop
    v_at := series_start(p_starts_at, k);
    if teacher_clash(v_t, v_at, p_minutes, null, null, false) then
      if k = 0 then raise exception 'يوجد حجز في هذا الوقت. غيّر موعده أو ألغِه أولاً.'; end if;
      continue;
    end if;
    insert into teacher_blocks (teacher_id, starts_at, minutes, note) values (v_t, v_at, p_minutes, nullif(trim(p_note), ''));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Opens a closed hour; with p_all, also every later closed hour at the same weekday and time.
create or replace function public.teacher_unblock(p_block uuid, p_all boolean default false) returns int
language plpgsql security definer set search_path = public as $$
declare k teacher_blocks%rowtype; v_n int;
begin
  select * into k from teacher_blocks where id = p_block and teacher_id = my_teacher_id();
  if not found then raise exception 'الساعة غير موجودة'; end if;
  delete from teacher_blocks x where x.teacher_id = k.teacher_id and (x.id = k.id or (p_all and x.starts_at > k.starts_at
     and extract(dow from x.starts_at at time zone 'Asia/Jerusalem') = extract(dow from k.starts_at at time zone 'Asia/Jerusalem')
     and (x.starts_at at time zone 'Asia/Jerusalem')::time = (k.starts_at at time zone 'Asia/Jerusalem')::time
     and x.minutes = k.minutes));
  get diagnostics v_n = row_count;
  -- People waiting for this teacher hear that time opened up.
  perform waitlist_notify_next(o.id, 1, 'hours') from offerings o where o.teacher_id = k.teacher_id and o.type = 'private' and o.active;
  return v_n;
end $$;

-- ================= the teacher's students =================
-- Everyone who booked with this teacher or wrote to them; the only people a teacher may book in.
create or replace function public.my_students()
returns table (user_id uuid, child_id uuid, name text, guardian text, last_at timestamptz)
language sql stable security definer set search_path = public as $$
  with mine as (select my_teacher_id() t),
  people as (
    select b.booked_by u, b.child_id c, max(coalesce(b.starts_at, b.created_at)) at
      from bookings b join offerings o on o.id = b.offering_id, mine
     where o.teacher_id = mine.t or o.course_teacher_id = mine.t
     group by b.booked_by, b.child_id
    union all
    select cv.user_id, null, max(cv.created_at) from conversations cv, mine where cv.teacher_id = mine.t group by cv.user_id
  )
  select p.u, p.c, coalesce(ch.name, pr.full_name, 'طالب'), case when p.c is not null then pr.full_name end, max(p.at)
    from people p join profiles pr on pr.id = p.u left join children ch on ch.id = p.c
   group by p.u, p.c, ch.name, pr.full_name
   order by max(p.at) desc
$$;

-- ================= putting a student into an hour =================
create or replace function public.teacher_add_booking(
  p_offering uuid, p_student uuid, p_child uuid default null, p_starts_at timestamptz default null,
  p_weekly boolean default false, p_mode public.place_kind default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_series uuid; v_mode place_kind; k int; v_at timestamptz; v_created int := 0; v_skipped text[] := '{}'; v_tname text;
begin
  select * into o from offerings where id = p_offering;
  if not found or o.type <> 'private' or not is_offering_owner(o.id) then raise exception 'اختر أحد دروسك الخصوصية'; end if;
  if not exists (select 1 from my_students() s where s.user_id = p_student and s.child_id is not distinct from p_child) then
    raise exception 'يمكنك إضافة طلابك فقط (من حجز معك أو راسلك)';
  end if;
  if not is_active_user(p_student) then raise exception 'حساب هذا الطالب موقوف'; end if;
  if p_starts_at is null or p_starts_at < now() then raise exception 'اختر موعداً قادماً'; end if;
  if teacher_clash(o.teacher_id, p_starts_at, o.minutes) then raise exception 'هذا الوقت غير فارغ (حجز أو ساعة مغلقة أو وقت الاستراحة)'; end if;
  v_mode := coalesce(p_mode, o.places[1]);
  if not v_mode = any(o.places) then v_mode := o.places[1]; end if;
  select name into v_tname from teachers where id = o.teacher_id;

  if p_weekly then
    insert into recurring_series (offering_id, booked_by, child_id, first_start, minutes, mode, pay_method, price, status)
    values (o.id, p_student, p_child, p_starts_at, o.minutes, v_mode, 'cash', o.price, 'active') returning id into v_series;
  end if;
  for k in 0 .. case when p_weekly then series_window_weeks() - 1 else 0 end loop
    v_at := series_start(p_starts_at, k);
    if k > 0 and teacher_clash(o.teacher_id, v_at, o.minutes) then v_skipped := v_skipped || fmt_time(v_at); continue; end if;
    insert into bookings (offering_id, booked_by, child_id, starts_at, minutes, status, pay_method, weekly, mode, series_id, price)
    values (o.id, p_student, p_child, v_at, o.minutes, 'confirmed', 'cash', p_weekly, v_mode, v_series, o.price);
    v_created := v_created + 1;
  end loop;

  insert into notifications (user_id, kind, body, link) values (
    p_student, 'booking_answer',
    case when p_weekly
      then format('ثبّت لك أ. %s موعداً أسبوعياً: %s، كل %s الساعة %s%s.', v_tname, o.title,
                  (array['أحد','اثنين','ثلاثاء','أربعاء','خميس','جمعة','سبت'])[extract(dow from p_starts_at at time zone 'Asia/Jerusalem')::int + 1],
                  hhmm(p_starts_at), coalesce(' لـ' || (select name from children where id = p_child), ''))
      else format('حجز لك أ. %s حصة: %s، %s%s.', v_tname, o.title, fmt_time(p_starts_at), coalesce(' لـ' || (select name from children where id = p_child), '')) end,
    '/schedule');
  return jsonb_build_object('created', v_created, 'skipped', to_jsonb(v_skipped));
end $$;

-- ================= moving a booking =================
create or replace function public.teacher_move_booking(p_booking uuid, p_new_start timestamptz, p_scope text default 'one', p_note text default null)
returns int
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; o offerings%rowtype; v_shift interval; x record; v_new timestamptz; v_n int := 0; v_note text;
begin
  select * into b from bookings where id = p_booking;
  if not found or not is_offering_owner(b.offering_id) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  select * into o from offerings where id = b.offering_id;
  if o.type <> 'private' or b.starts_at is null then raise exception 'مواعيد المجموعات والدورات تُغيَّر من صفحة اللقاءات'; end if;
  if b.status not in ('pending','confirmed') then raise exception 'هذا الحجز ملغى'; end if;
  if p_new_start is null or p_new_start < now() then raise exception 'اختر موعداً قادماً'; end if;
  v_note := nullif(trim(p_note), '');
  -- Shift in local clock time, so a weekly slot keeps its hour across clock changes.
  v_shift := (p_new_start at time zone 'Asia/Jerusalem') - (b.starts_at at time zone 'Asia/Jerusalem');

  if p_scope = 'following' and b.series_id is not null then
    for x in select * from bookings where series_id = b.series_id and starts_at >= b.starts_at and status in ('pending','confirmed') order by starts_at loop
      v_new := ((x.starts_at at time zone 'Asia/Jerusalem') + v_shift) at time zone 'Asia/Jerusalem';
      if teacher_clash(o.teacher_id, v_new, x.minutes, b.series_id) then
        raise exception 'الموعد الجديد يتعارض يوم %. اختر وقتاً آخر أو غيّر هذه الحصة فقط.', fmt_time(v_new);
      end if;
    end loop;
    for x in select * from bookings where series_id = b.series_id and starts_at >= b.starts_at and status in ('pending','confirmed') loop
      update bookings set starts_at = ((x.starts_at at time zone 'Asia/Jerusalem') + v_shift) at time zone 'Asia/Jerusalem', changed_at = now() where id = x.id;
      delete from reminder_log where key like 's:' || x.id || ':%' or key like 't:b' || x.id || ':%';
      v_n := v_n + 1;
    end loop;
    update recurring_series set first_start = ((first_start at time zone 'Asia/Jerusalem') + v_shift) at time zone 'Asia/Jerusalem' where id = b.series_id;
    insert into notifications (user_id, kind, body, link) values (b.booked_by, 'schedule_changed',
      format('غيّر المعلم موعدك الأسبوعي في %s: من الآن كل %s الساعة %s (أول حصة %s).%s إذا لم يناسبك يمكنك الإلغاء مجاناً.', o.title,
             (array['أحد','اثنين','ثلاثاء','أربعاء','خميس','جمعة','سبت'])[extract(dow from p_new_start at time zone 'Asia/Jerusalem')::int + 1],
             hhmm(p_new_start), fmt_time(p_new_start), coalesce(' «' || v_note || '»', '')), '/schedule');
    return v_n;
  end if;

  if teacher_clash(o.teacher_id, p_new_start, b.minutes, null, b.id) then
    raise exception 'الموعد الجديد غير فارغ (حجز آخر أو ساعة مغلقة أو وقت الاستراحة)';
  end if;
  update bookings set starts_at = p_new_start, changed_at = now() where id = b.id;
  delete from reminder_log where key like 's:' || b.id || ':%' or key like 't:b' || b.id || ':%';
  insert into notifications (user_id, kind, body, link) values (b.booked_by, 'schedule_changed',
    format('غيّر المعلم موعد حصتك %s: من %s إلى %s.%s إذا لم يناسبك يمكنك الإلغاء مجاناً.', o.title, fmt_time(b.starts_at), fmt_time(p_new_start),
           coalesce(' «' || v_note || '»', '')), '/schedule');
  return 1;
end $$;

-- ================= cancelling by the teacher =================
create or replace function public.teacher_cancel_booking(p_booking uuid, p_scope text default 'one', p_reason text default null)
returns int
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; o offerings%rowtype; v_n int; v_reason text;
begin
  select * into b from bookings where id = p_booking;
  if not found or not is_offering_owner(b.offering_id) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  if b.status not in ('pending','confirmed') then raise exception 'هذا الحجز ملغى سابقاً'; end if;
  select * into o from offerings where id = b.offering_id;
  v_reason := nullif(trim(p_reason), '');
  if p_scope = 'series' and b.series_id is not null then
    update bookings set status = 'cancelled' where series_id = b.series_id and status in ('pending','confirmed')
      and coalesce(starts_at, now() + interval '1 day') >= coalesce(b.starts_at, now());
    get diagnostics v_n = row_count;
    update recurring_series set status = 'cancelled', cancelled_at = now() where id = b.series_id;
    insert into notifications (user_id, kind, body, link) values (b.booked_by, 'booking_cancelled',
      format('أوقف المعلم الموعد الأسبوعي: %s (%s حصص).%s', o.title, v_n, coalesce(' «' || v_reason || '»', '')), '/schedule');
  else
    update bookings set status = 'cancelled' where id = b.id;
    v_n := 1;
    insert into notifications (user_id, kind, body, link) values (b.booked_by, 'booking_cancelled',
      format('ألغى المعلم حصة %s%s.%s', o.title, coalesce(' يوم ' || fmt_time(b.starts_at), ''), coalesce(' «' || v_reason || '»', '')), '/schedule');
  end if;
  if o.type = 'private' then perform waitlist_notify_next(o.id, 1, 'hours'); end if;
  return v_n;
end $$;

-- A lesson the teacher moved can be cancelled by the student for free, even close to the time.
create or replace function public.cancel_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_owner uuid; v_title text;
begin
  select * into b from bookings where id = p_booking and booked_by = auth.uid();
  if not found then raise exception 'الحجز غير موجود'; end if;
  if b.status not in ('pending','confirmed') then raise exception 'الحجز ملغى سابقاً'; end if;
  if b.starts_at is not null and b.starts_at < now() + interval '24 hours' and b.status = 'confirmed' and b.changed_at is null then
    raise exception 'الإلغاء المجاني متاح حتى 24 ساعة قبل الحصة. تواصل مع المعلم.';
  end if;
  update bookings set status = 'cancelled' where id = p_booking;
  v_owner := offering_owner_user(b.offering_id);
  select title into v_title from offerings where id = b.offering_id;
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (v_owner, 'booking_cancelled',
      format('أُلغي حجز: %s%s', v_title, coalesce('، ' || fmt_time(b.starts_at), '')), '/teach');
  end if;
end $$;

-- ================= one call for the teacher's calendar page =================
create or replace function public.my_teacher_calendar(p_from timestamptz, p_to timestamptz)
returns table (kind text, id uuid, starts_at timestamptz, minutes int, title text, who text, status text,
               series_id uuid, mode public.place_kind, note text, offering_id uuid, changed boolean)
language sql stable security definer set search_path = public as $$
  with me as (select my_teacher_id() t)
  select 'booking', b.id, b.starts_at, b.minutes, o.title, coalesce(c.name, p.full_name, 'طالب'), b.status::text,
         b.series_id, b.mode, null, o.id, b.changed_at is not null
    from bookings b join offerings o on o.id = b.offering_id join me on o.teacher_id = me.t
    left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
   where b.status in ('pending','confirmed') and b.starts_at between p_from and p_to
  union all
  select 'session', s.id, s.starts_at, s.minutes, o.title,
         (select count(*)::text from bookings x where x.status = 'confirmed' and (x.session_id = s.id or (o.type = 'course' and x.offering_id = o.id and x.session_id is null))),
         case when o.institute_id is not null then 'institute' else 'group' end, null, null, null, o.id, s.changed
    from sessions s join offerings o on o.id = s.offering_id join me on (o.teacher_id = me.t or o.course_teacher_id = me.t)
   where not s.cancelled and s.starts_at between p_from and p_to
  union all
  select 'block', k.id, k.starts_at, k.minutes, null, null, null, null, null, k.note, null, false
    from teacher_blocks k join me on k.teacher_id = me.t
   where k.starts_at between p_from and p_to
  order by 3
$$;

revoke execute on function public.teacher_block, public.teacher_unblock, public.my_students, public.teacher_add_booking,
  public.teacher_move_booking, public.teacher_cancel_booking, public.my_teacher_calendar, public.my_teacher_id from anon, public;
grant execute on function public.teacher_block, public.teacher_unblock, public.my_students, public.teacher_add_booking,
  public.teacher_move_booking, public.teacher_cancel_booking, public.my_teacher_calendar, public.my_teacher_id to authenticated;
grant execute on function public.teacher_busy, public.teacher_clash to anon, authenticated;
