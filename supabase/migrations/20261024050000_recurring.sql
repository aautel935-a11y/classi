-- Classi: instant confirmation, weekly recurring bookings, breaks between lessons.

-- ================= settings =================
alter table public.offerings add column if not exists auto_confirm boolean not null default false; -- private lessons: confirm without waiting
alter table public.offerings add column if not exists allow_weekly boolean not null default false; -- private & group: students may book every week
alter table public.teachers  add column if not exists buffer_minutes int not null default 0
  check (buffer_minutes in (0, 5, 10, 15, 30));

-- Weeks booked ahead for a weekly series; the daily job keeps this window full.
create or replace function public.series_window_weeks() returns int language sql immutable as $$ select 8 $$;

-- ================= weekly series =================
create table if not exists public.recurring_series (
  id           uuid primary key default gen_random_uuid(),
  offering_id  uuid not null references public.offerings(id) on delete cascade,
  booked_by    uuid not null references public.profiles(id) on delete cascade,
  child_id     uuid references public.children(id) on delete set null,
  first_start  timestamptz not null,              -- the first lesson; later ones are the same local weekday and time
  minutes      int not null default 60,
  mode         public.place_kind,
  pay_method   text not null default 'bit',
  price        int,
  status       text not null default 'pending' check (status in ('pending','active','cancelled')),
  created_at   timestamptz not null default now(),
  cancelled_at timestamptz
);
alter table public.bookings add column if not exists series_id uuid references public.recurring_series(id) on delete set null;
create index if not exists bookings_series on public.bookings (series_id);

alter table public.recurring_series enable row level security;
create policy "see own or staff series" on public.recurring_series for select
  using (booked_by = auth.uid() or is_offering_staff(offering_id));
grant select on public.recurring_series to authenticated;

-- Local (Israel) start of week k of a series, so 17:00 stays 17:00 across clock changes.
create or replace function public.series_start(p_first timestamptz, p_week int) returns timestamptz
language sql immutable as $$
  select ((p_first at time zone 'Asia/Jerusalem') + make_interval(weeks => p_week)) at time zone 'Asia/Jerusalem'
$$;

-- Does [start, start+minutes) clash with the teacher's lessons, keeping their break before and after?
create or replace function public.teacher_clash(p_teacher uuid, p_start timestamptz, p_minutes int, p_ignore_series uuid default null)
returns boolean
language sql stable security definer set search_path = public as $$
  with buf as (select make_interval(mins => coalesce((select buffer_minutes from teachers where id = p_teacher), 0)) b)
  select exists (
    select 1 from buf, (
      select bk.starts_at s, bk.minutes m from bookings bk join offerings o on o.id = bk.offering_id
       where o.teacher_id = p_teacher and bk.status in ('pending','confirmed') and bk.starts_at is not null
         and (p_ignore_series is null or bk.series_id is distinct from p_ignore_series)
         and bk.starts_at between p_start - interval '6 hours' and p_start + interval '6 hours'
      union all
      select se.starts_at, se.minutes from sessions se join offerings o on o.id = se.offering_id
       where (o.teacher_id = p_teacher or o.course_teacher_id = p_teacher) and not se.cancelled
         and se.starts_at between p_start - interval '6 hours' and p_start + interval '6 hours'
    ) busy
    where tstzrange(busy.s - buf.b, busy.s + make_interval(mins => busy.m) + buf.b)
       && tstzrange(p_start, p_start + make_interval(mins => p_minutes))
  )
$$;

-- ================= single booking (now honours instant confirmation and breaks) =================
create or replace function public.create_booking(
  p_offering uuid,
  p_child    uuid default null,
  p_starts_at timestamptz default null,
  p_session  uuid default null,
  p_pay      text default 'bit',
  p_weekly   boolean default false,
  p_mode     public.place_kind default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  o offerings%rowtype;
  v_id uuid;
  v_status booking_status;
  v_owner uuid;
  v_who text;
  v_mode place_kind;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  select * into o from offerings where id = p_offering and active and not moderation_hidden;
  if not found or not offering_owner_verified(o.id) then raise exception 'هذا العرض غير متاح'; end if;
  if is_offering_owner(o.id) then raise exception 'لا يمكنك حجز عرضك أنت'; end if;
  if p_child is not null and not exists (select 1 from children where id = p_child and guardian_id = auth.uid()) then
    raise exception 'هذا الطالب غير مرتبط بحسابك';
  end if;
  v_mode := coalesce(p_mode, o.places[1]);
  if not v_mode = any(o.places) then raise exception 'طريقة الحضور غير متاحة لهذا العرض'; end if;

  if o.type = 'private' then
    if p_starts_at is null or p_starts_at < now() then raise exception 'اختر موعداً قادماً'; end if;
    if teacher_clash(o.teacher_id, p_starts_at, o.minutes) then raise exception 'الموعد لم يعد متاحاً، اختر موعداً آخر'; end if;
    v_status := case when o.auto_confirm then 'confirmed' else 'pending' end;
  elsif o.type = 'group' then
    if p_session is null or not exists (select 1 from sessions where id = p_session and offering_id = o.id and not cancelled and starts_at > now()) then
      raise exception 'اختر لقاءً قادماً';
    end if;
    if seats_taken(o.id, p_session) >= o.seats then raise exception 'لا توجد مقاعد فارغة في هذا اللقاء'; end if;
    v_status := 'confirmed';
  elsif o.type = 'course' then
    if seats_taken(o.id) >= o.seats then raise exception 'الدورة ممتلئة'; end if;
    v_status := 'confirmed';
  else
    v_status := 'confirmed';
  end if;

  insert into bookings (offering_id, session_id, booked_by, child_id, starts_at, minutes, status, pay_method, weekly, mode)
  values (o.id, p_session, auth.uid(), p_child, p_starts_at, o.minutes, v_status, p_pay, false, v_mode)
  returning id into v_id;

  v_owner := offering_owner_user(o.id);
  select coalesce((select name from children where id = p_child), (select full_name from profiles where id = auth.uid())) into v_who;
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (
      v_owner,
      case when v_status = 'pending' then 'booking_request' else 'booking_new' end,
      case when v_status = 'pending'
        then format('طلب حجز جديد من %s: %s، %s (%s)', v_who, o.title, fmt_time(p_starts_at),
                    case v_mode when 'online' then 'أونلاين' when 'home' then 'حضوري' else 'في المعهد' end)
        when o.type = 'private'
        then format('حجز مؤكد تلقائياً من %s: %s، %s', v_who, o.title, fmt_time(p_starts_at))
        else format('حجز جديد من %s: %s', v_who, o.title) end,
      case when o.institute_id is not null then '/manage' else '/teach' end);
  end if;
  if o.type = 'private' and v_status = 'confirmed' then
    insert into notifications (user_id, kind, body, link)
    values (auth.uid(), 'booking_answer', format('تم تأكيد حصتك فوراً: %s، %s', o.title, fmt_time(p_starts_at)), '/schedule');
  end if;
  return v_id;
end $$;

-- ================= weekly booking =================
-- Books the chosen lesson and the same weekly time for the next weeks.
-- The first lesson must be free; later weeks that clash are skipped and reported.
create or replace function public.create_weekly_booking(
  p_offering uuid,
  p_child    uuid default null,
  p_starts_at timestamptz default null,
  p_session  uuid default null,
  p_pay      text default 'bit',
  p_mode     public.place_kind default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o offerings%rowtype;
  v_series uuid;
  v_status booking_status;
  v_mode place_kind;
  v_first timestamptz;
  v_at timestamptz;
  v_created int := 0;
  v_skipped text[] := '{}';
  v_owner uuid;
  v_who text;
  s record;
  k int;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  select * into o from offerings where id = p_offering and active and not moderation_hidden;
  if not found or not offering_owner_verified(o.id) then raise exception 'هذا العرض غير متاح'; end if;
  if not o.allow_weekly or o.type not in ('private','group') then raise exception 'هذا العرض لا يسمح بالحجز الأسبوعي'; end if;
  if is_offering_owner(o.id) then raise exception 'لا يمكنك حجز عرضك أنت'; end if;
  if not is_active_user() then raise exception 'حسابك موقوف ولا يمكنه الحجز'; end if;
  if p_child is not null and not exists (select 1 from children where id = p_child and guardian_id = auth.uid()) then
    raise exception 'هذا الطالب غير مرتبط بحسابك';
  end if;
  v_mode := coalesce(p_mode, o.places[1]);
  if not v_mode = any(o.places) then raise exception 'طريقة الحضور غير متاحة لهذا العرض'; end if;

  if o.type = 'private' then
    if p_starts_at is null or p_starts_at < now() then raise exception 'اختر موعداً قادماً'; end if;
    if teacher_clash(o.teacher_id, p_starts_at, o.minutes) then raise exception 'الموعد لم يعد متاحاً، اختر موعداً آخر'; end if;
    v_first := p_starts_at;
    v_status := case when o.auto_confirm then 'confirmed' else 'pending' end;
  else
    select starts_at into v_first from sessions where id = p_session and offering_id = o.id and not cancelled and starts_at > now();
    if v_first is null then raise exception 'اختر لقاءً قادماً'; end if;
    v_status := 'confirmed';
  end if;

  insert into recurring_series (offering_id, booked_by, child_id, first_start, minutes, mode, pay_method, price, status)
  values (o.id, auth.uid(), p_child, v_first, o.minutes, v_mode, p_pay, o.price,
          case when v_status = 'confirmed' then 'active' else 'pending' end)
  returning id into v_series;

  if o.type = 'private' then
    for k in 0 .. series_window_weeks() - 1 loop
      v_at := series_start(v_first, k);
      if k > 0 and teacher_clash(o.teacher_id, v_at, o.minutes) then
        v_skipped := v_skipped || fmt_time(v_at);
        continue;
      end if;
      insert into bookings (offering_id, booked_by, child_id, starts_at, minutes, status, pay_method, weekly, mode, series_id)
      values (o.id, auth.uid(), p_child, v_at, o.minutes, v_status, p_pay, true, v_mode, v_series);
      v_created := v_created + 1;
    end loop;
  else
    for s in select se.id, se.starts_at from sessions se
              where se.offering_id = o.id and not se.cancelled and se.starts_at >= v_first order by se.starts_at
              limit series_window_weeks() loop
      if seats_taken(o.id, s.id) >= o.seats
         or exists (select 1 from bookings b where b.session_id = s.id and b.booked_by = auth.uid()
                    and b.child_id is not distinct from p_child and b.status in ('pending','confirmed')) then
        v_skipped := v_skipped || fmt_time(s.starts_at);
        continue;
      end if;
      insert into bookings (offering_id, session_id, booked_by, child_id, minutes, status, pay_method, weekly, mode, series_id)
      values (o.id, s.id, auth.uid(), p_child, o.minutes, 'confirmed', p_pay, true, v_mode, v_series);
      v_created := v_created + 1;
    end loop;
    if v_created = 0 then raise exception 'لا توجد مقاعد فارغة في اللقاءات القادمة'; end if;
  end if;

  v_owner := offering_owner_user(o.id);
  select coalesce((select name from children where id = p_child), (select full_name from profiles where id = auth.uid())) into v_who;
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (
      v_owner,
      case when v_status = 'pending' then 'booking_request' else 'booking_new' end,
      format('%s %s: %s، كل %s الساعة %s (%s حصص)',
             case when v_status = 'pending' then 'طلب حجز أسبوعي من' else 'حجز أسبوعي مؤكد من' end,
             v_who, o.title,
             (array['أحد','اثنين','ثلاثاء','أربعاء','خميس','جمعة','سبت'])[extract(dow from v_first at time zone 'Asia/Jerusalem')::int + 1],
             to_char(v_first at time zone 'Asia/Jerusalem', 'HH24:MI'), v_created),
      '/teach');
  end if;
  if v_status = 'confirmed' then
    insert into notifications (user_id, kind, body, link)
    values (auth.uid(), 'booking_answer', format('تم تثبيت موعدك الأسبوعي: %s، أول حصة %s', o.title, fmt_time(v_first)), '/schedule');
  end if;

  return jsonb_build_object('series_id', v_series, 'status', v_status, 'created', v_created, 'skipped', to_jsonb(v_skipped));
end $$;

-- ================= answering, cancelling =================
-- Accepting or declining one booking of a weekly request answers the whole series.
create or replace function public.respond_booking(p_booking uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_title text; v_n int;
begin
  select * into b from bookings where id = p_booking;
  if not found or not is_offering_owner(b.offering_id) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  if b.status <> 'pending' then raise exception 'تم الرد على هذا الطلب سابقاً'; end if;
  select title into v_title from offerings where id = b.offering_id;

  if b.series_id is not null then
    update bookings set status = case when p_accept then 'confirmed'::booking_status else 'declined'::booking_status end
     where series_id = b.series_id and status = 'pending';
    get diagnostics v_n = row_count;
    update recurring_series set status = case when p_accept then 'active' else 'cancelled' end,
                                cancelled_at = case when p_accept then null else now() end
     where id = b.series_id;
    insert into notifications (user_id, kind, body, link) values (
      b.booked_by, 'booking_answer',
      case when p_accept then format('وافق المعلم على موعدك الأسبوعي: %s (%s حصص)، أولها %s', v_title, v_n, fmt_time(b.starts_at))
           else format('اعتذر المعلم عن الموعد الأسبوعي: %s. اختر موعداً آخر.', v_title) end,
      '/schedule');
    return;
  end if;

  update bookings set status = case when p_accept then 'confirmed'::booking_status else 'declined'::booking_status end where id = p_booking;
  insert into notifications (user_id, kind, body, link) values (
    b.booked_by, 'booking_answer',
    case when p_accept then format('تم تأكيد حصتك: %s، %s', v_title, fmt_time(b.starts_at))
         else format('اعتذر المعلم عن الموعد: %s، %s. اختر موعداً آخر.', v_title, fmt_time(b.starts_at)) end,
    '/schedule');
end $$;

-- Stop a weekly series: the student or the teacher/institute cancels all lessons from now on.
create or replace function public.cancel_series(p_series uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r recurring_series%rowtype; v_n int; v_title text; v_staff boolean; v_owner uuid;
begin
  select * into r from recurring_series where id = p_series;
  if not found then raise exception 'السلسلة غير موجودة'; end if;
  v_staff := is_offering_owner(r.offering_id);
  if r.booked_by <> auth.uid() and not v_staff then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  if r.status = 'cancelled' then raise exception 'أُلغي هذا الموعد الأسبوعي سابقاً'; end if;
  update bookings b set status = 'cancelled'
   where b.series_id = p_series and b.status in ('pending','confirmed')
     and coalesce(b.starts_at, (select starts_at from sessions where id = b.session_id)) > now();
  get diagnostics v_n = row_count;
  update recurring_series set status = 'cancelled', cancelled_at = now() where id = p_series;
  select title into v_title from offerings where id = r.offering_id;
  v_owner := offering_owner_user(r.offering_id);
  insert into notifications (user_id, kind, body, link)
  select case when v_staff then r.booked_by else v_owner end, 'booking_cancelled',
         format('أُلغي الموعد الأسبوعي: %s (%s حصص قادمة)', v_title, v_n),
         case when v_staff then '/schedule' else '/teach' end
  where (case when v_staff then r.booked_by else v_owner end) is not null;
  return v_n;
end $$;

-- Keeps every active series booked for the coming weeks (run daily, safe to run any time).
create or replace function public.extend_recurring() returns int
language plpgsql security definer set search_path = public as $$
declare r record; o offerings%rowtype; v_last timestamptz; v_week int; v_at timestamptz; v_added int := 0; s record;
begin
  for r in select * from recurring_series where status = 'active' loop
    select * into o from offerings where id = r.offering_id;
    if o.id is null or not o.active or o.moderation_hidden or not is_active_user(r.booked_by) then continue; end if;
    if o.type = 'private' then
      select max(starts_at) into v_last from bookings where series_id = r.id;
      v_week := coalesce(round(extract(epoch from (v_last at time zone 'Asia/Jerusalem') - (r.first_start at time zone 'Asia/Jerusalem')) / 604800)::int, -1);
      loop
        v_week := v_week + 1;
        v_at := series_start(r.first_start, v_week);
        exit when v_at > now() + make_interval(weeks => series_window_weeks());
        if v_at <= now() then continue; end if;
        if teacher_clash(o.teacher_id, v_at, r.minutes) then
          insert into notifications (user_id, kind, body, link)
          values (r.booked_by, 'booking_cancelled', format('لم نتمكن من تثبيت موعدك الأسبوعي يوم %s لأن المعلم مشغول. راسل المعلم لموعد بديل.', fmt_time(v_at)), '/schedule');
          continue;
        end if;
        insert into bookings (offering_id, booked_by, child_id, starts_at, minutes, status, pay_method, weekly, mode, series_id, price)
        values (o.id, r.booked_by, r.child_id, v_at, r.minutes, 'confirmed', r.pay_method, true, r.mode, r.id, r.price);
        v_added := v_added + 1;
      end loop;
    else
      for s in select se.id from sessions se
                where se.offering_id = o.id and not se.cancelled and se.starts_at > now()
                  and se.starts_at <= now() + make_interval(weeks => series_window_weeks())
                  and not exists (select 1 from bookings b where b.session_id = se.id and b.series_id = r.id) loop
        if seats_taken(o.id, s.id) < o.seats then
          insert into bookings (offering_id, session_id, booked_by, child_id, minutes, status, pay_method, weekly, mode, series_id, price)
          values (o.id, s.id, r.booked_by, r.child_id, r.minutes, 'confirmed', r.pay_method, true, r.mode, r.id, r.price);
          v_added := v_added + 1;
        end if;
      end loop;
    end if;
  end loop;
  return v_added;
end $$;

-- Booked times of a teacher widened by their break, for greying out slots.
create or replace function public.teacher_buffer(p_teacher uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select buffer_minutes from teachers where id = p_teacher), 0)
$$;

-- The roster helper returns the series too.
drop function if exists public.owner_bookings(uuid);
create or replace function public.owner_bookings(p_offering uuid default null)
returns table (
  booking_id uuid, offering_id uuid, offering_title text, offering_type public.offering_type,
  student_name text, starts_at timestamptz, session_id uuid, status public.booking_status,
  pay_method text, created_at timestamptz, mode public.place_kind, weekly boolean, series_id uuid, series_count int)
language sql stable security definer set search_path = public as $$
  select b.id, o.id, o.title, o.type,
         coalesce(c.name, p.full_name, 'طالب'), coalesce(b.starts_at, s.starts_at), b.session_id,
         b.status, b.pay_method, b.created_at, b.mode, b.weekly, b.series_id,
         case when b.series_id is null then null
              else (select count(*)::int from bookings x where x.series_id = b.series_id and x.status in ('pending','confirmed')) end
  from bookings b
  join offerings o on o.id = b.offering_id
  left join children c on c.id = b.child_id
  left join profiles p on p.id = b.booked_by
  left join sessions s on s.id = b.session_id
  where is_offering_staff(o.id) and (p_offering is null or o.id = p_offering)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;

revoke execute on function public.create_weekly_booking, public.cancel_series, public.owner_bookings from anon, public;
grant execute on function public.create_weekly_booking, public.cancel_series, public.owner_bookings, public.teacher_buffer to authenticated;
grant execute on function public.teacher_buffer, public.extend_recurring to anon, authenticated;
