-- Classi: initial schema
-- Every lesson, group, course and recorded package is one row in "offerings";
-- its "type" decides how it is booked. Writes that touch other people's data
-- (booking, accepting, rescheduling) go through security-definer functions
-- that check permissions and create notifications in the same transaction.

-- ---------- types ----------
create type public.offering_type as enum ('private','group','course','recorded');
create type public.place_kind    as enum ('home','online','center');
create type public.booking_status as enum ('pending','confirmed','declined','cancelled');
create type public.verify_status as enum ('pending','verified','rejected');
create type public.app_role      as enum ('guardian','student','teacher','institute','admin');

-- ---------- people ----------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  phone       text,
  town        text,
  roles       public.app_role[] not null default '{guardian}',
  active_role public.app_role not null default 'guardian',
  created_at  timestamptz not null default now()
);

-- Children have no login of their own: the guardian books and pays for them.
create table public.children (
  id          uuid primary key default gen_random_uuid(),
  guardian_id uuid not null references public.profiles(id) on delete cascade,
  name        text not null check (length(name) between 1 and 60),
  grade       text,
  created_at  timestamptz not null default now()
);

create table public.subjects (id serial primary key, name text unique not null);
create table public.levels   (id serial primary key, name text unique not null, sort int not null default 0);

-- A teacher listing may exist before the teacher signs up (user_id null);
-- the teacher claims it later.
create table public.teachers (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid unique references public.profiles(id) on delete set null,
  name              text not null,
  town              text not null,
  subject_id        int references public.subjects(id),
  bio               text not null default '',
  years             int not null default 0,
  is_school_teacher boolean not null default false,
  verify            public.verify_status not null default 'pending',
  rating            numeric(2,1) not null default 0,
  reviews_count     int not null default 0,
  created_at        timestamptz not null default now()
);

create table public.institutes (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid references public.profiles(id) on delete set null,
  name          text not null,
  town          text not null,
  bio           text not null default '',
  verify        public.verify_status not null default 'pending',
  rating        numeric(2,1) not null default 0,
  reviews_count int not null default 0,
  created_at    timestamptz not null default now()
);

create table public.institute_teachers (
  institute_id uuid references public.institutes(id) on delete cascade,
  teacher_id   uuid references public.teachers(id) on delete cascade,
  primary key (institute_id, teacher_id)
);

create table public.rooms (
  id           uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes(id) on delete cascade,
  name         text not null,
  capacity     int not null default 14
);

-- ---------- what is offered ----------
create table public.offerings (
  id                uuid primary key default gen_random_uuid(),
  type              public.offering_type not null,
  teacher_id        uuid references public.teachers(id) on delete cascade,
  institute_id      uuid references public.institutes(id) on delete cascade,
  title             text not null check (length(title) between 3 and 120),
  subject_id        int references public.subjects(id),
  level_id          int references public.levels(id),
  places            public.place_kind[] not null default '{home}',
  price             int not null check (price >= 0),
  seats             int check (seats > 0),
  schedule_note     text,             -- e.g. "كل ثلاثاء 18:00"
  start_date        date,
  sessions_count    int,
  lessons_count     int,
  minutes           int not null default 60,
  course_teacher_id uuid references public.teachers(id),   -- teacher of an institute course
  default_room_id   uuid references public.rooms(id),
  active            boolean not null default true,
  created_at        timestamptz not null default now(),
  constraint one_owner check ((teacher_id is null) <> (institute_id is null)),
  constraint seats_needed check (type not in ('group','course') or seats is not null)
);
create index on public.offerings (type) where active;
create index on public.offerings (teacher_id);
create index on public.offerings (institute_id);

-- Weekly free hours of a teacher, for private lessons.
create table public.availability (
  id         uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.teachers(id) on delete cascade,
  weekday    smallint not null check (weekday between 0 and 6),  -- 0 = Sunday
  start_time time not null,
  end_time   time not null check (end_time > start_time)
);

-- Dated meetings of groups and courses.
create table public.sessions (
  id          uuid primary key default gen_random_uuid(),
  offering_id uuid not null references public.offerings(id) on delete cascade,
  seq         int not null,
  starts_at   timestamptz not null,
  minutes     int not null default 90,
  room_id     uuid references public.rooms(id),
  changed     boolean not null default false,
  cancelled   boolean not null default false,
  unique (offering_id, seq)
);
create index on public.sessions (room_id, starts_at);

create table public.bookings (
  id          uuid primary key default gen_random_uuid(),
  offering_id uuid not null references public.offerings(id) on delete cascade,
  session_id  uuid references public.sessions(id) on delete cascade, -- a group seat
  booked_by   uuid not null references public.profiles(id) on delete cascade,
  child_id    uuid references public.children(id) on delete set null,
  starts_at   timestamptz,                                             -- a private lesson
  minutes     int not null default 60,
  status      public.booking_status not null default 'pending',
  pay_method  text not null default 'bit',
  weekly      boolean not null default false,
  created_at  timestamptz not null default now()
);
create index on public.bookings (booked_by);
create index on public.bookings (offering_id, status);

create table public.attendance (
  session_id uuid references public.sessions(id) on delete cascade,
  booking_id uuid references public.bookings(id) on delete cascade,
  present    boolean not null,
  primary key (session_id, booking_id)
);

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null,
  body       text not null,
  link       text,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index on public.notifications (user_id, created_at desc);

create table public.change_log (
  id             uuid primary key default gen_random_uuid(),
  offering_id    uuid not null references public.offerings(id) on delete cascade,
  changed_by     uuid references public.profiles(id),
  body           text not null,
  notified_count int not null default 0,
  created_at     timestamptz not null default now()
);

create table public.reviews (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid unique not null references public.bookings(id) on delete cascade,
  stars      int not null check (stars between 1 and 5),
  body       text,
  created_at timestamptz not null default now()
);

-- ---------- helpers ----------
create or replace function public.my_teacher_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from teachers where user_id = auth.uid()
$$;

create or replace function public.is_offering_owner(p_offering uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from offerings o
    left join teachers t   on t.id = o.teacher_id
    left join institutes i on i.id = o.institute_id
    where o.id = p_offering
      and (t.user_id = auth.uid() or i.owner_id = auth.uid())
  )
$$;

-- Owner's account to notify for an offering (teacher or institute owner).
create or replace function public.offering_owner_user(p_offering uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(t.user_id, i.owner_id)
  from offerings o
  left join teachers t   on t.id = o.teacher_id
  left join institutes i on i.id = o.institute_id
  where o.id = p_offering
$$;

create or replace function public.fmt_time(ts timestamptz) returns text
language sql immutable as $$
  select to_char(ts at time zone 'Asia/Jerusalem', 'DD/MM HH24:MI')
$$;

-- New account -> profile row.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, phone)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''), new.phone)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Busy times of a teacher (no personal data), so the booking screen can grey them out.
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
$$;

-- Seats taken per offering / session, readable by everyone.
create or replace function public.seats_taken(p_offering uuid, p_session uuid default null) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from bookings
  where offering_id = p_offering
    and status in ('pending','confirmed')
    and (p_session is null or session_id = p_session)
$$;

-- ---------- booking ----------
create or replace function public.create_booking(
  p_offering uuid,
  p_child    uuid default null,
  p_starts_at timestamptz default null,
  p_session  uuid default null,
  p_pay      text default 'bit',
  p_weekly   boolean default false
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  o offerings%rowtype;
  v_id uuid;
  v_status booking_status;
  v_owner uuid;
  v_who text;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  select * into o from offerings where id = p_offering and active;
  if not found then raise exception 'هذا العرض غير متاح'; end if;

  if p_child is not null and not exists (select 1 from children where id = p_child and guardian_id = auth.uid()) then
    raise exception 'هذا الطالب غير مرتبط بحسابك';
  end if;

  if o.type = 'private' then
    if p_starts_at is null or p_starts_at < now() then raise exception 'اختر موعداً قادماً'; end if;
    if exists (select 1 from teacher_busy(o.teacher_id, p_starts_at - interval '3 hours', p_starts_at + interval '3 hours') b
               where tstzrange(b.starts_at, b.starts_at + make_interval(mins => b.minutes))
                  && tstzrange(p_starts_at, p_starts_at + make_interval(mins => o.minutes))) then
      raise exception 'الموعد لم يعد متاحاً، اختر موعداً آخر';
    end if;
    v_status := 'pending';
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

  insert into bookings (offering_id, session_id, booked_by, child_id, starts_at, minutes, status, pay_method, weekly)
  values (o.id, p_session, auth.uid(), p_child, p_starts_at, o.minutes, v_status, p_pay, coalesce(p_weekly, false))
  returning id into v_id;

  v_owner := offering_owner_user(o.id);
  select coalesce((select name from children where id = p_child), (select full_name from profiles where id = auth.uid())) into v_who;
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (
      v_owner,
      case when v_status = 'pending' then 'booking_request' else 'booking_new' end,
      case when v_status = 'pending'
        then format('طلب حجز جديد من %s: %s، %s', v_who, o.title, fmt_time(p_starts_at))
        else format('حجز جديد من %s: %s', v_who, o.title) end,
      '/teach');
  end if;
  return v_id;
end $$;

create or replace function public.respond_booking(p_booking uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_title text;
begin
  select * into b from bookings where id = p_booking;
  if not found or not is_offering_owner(b.offering_id) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  if b.status <> 'pending' then raise exception 'تم الرد على هذا الطلب سابقاً'; end if;
  update bookings set status = case when p_accept then 'confirmed'::booking_status else 'declined'::booking_status end where id = p_booking;
  select title into v_title from offerings where id = b.offering_id;
  insert into notifications (user_id, kind, body, link) values (
    b.booked_by, 'booking_answer',
    case when p_accept then format('تم تأكيد حصتك: %s، %s', v_title, fmt_time(b.starts_at))
         else format('اعتذر المعلم عن الموعد: %s، %s. اختر موعداً آخر.', v_title, fmt_time(b.starts_at)) end,
    '/schedule');
end $$;

create or replace function public.cancel_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_owner uuid; v_title text;
begin
  select * into b from bookings where id = p_booking and booked_by = auth.uid();
  if not found then raise exception 'الحجز غير موجود'; end if;
  if b.status not in ('pending','confirmed') then raise exception 'الحجز ملغى سابقاً'; end if;
  if b.starts_at is not null and b.starts_at < now() + interval '24 hours' and b.status = 'confirmed' then
    raise exception 'الإلغاء المجاني متاح حتى 24 ساعة قبل الحصة. تواصل مع المعلم.';
  end if;
  update bookings set status = 'cancelled' where id = p_booking;
  v_owner := offering_owner_user(b.offering_id);
  select title into v_title from offerings where id = b.offering_id;
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (v_owner, 'booking_cancelled', format('أُلغي حجز: %s', v_title), '/teach');
  end if;
end $$;

-- ---------- rescheduling (institute or teacher) ----------
-- Moves one session, or it and every later one, by the same shift; checks room
-- and teacher clashes; notifies the course teacher, every booker, and logs it.
create or replace function public.reschedule_session(
  p_session   uuid,
  p_starts_at timestamptz,
  p_room      uuid default null,
  p_scope     text default 'one',     -- 'one' | 'following'
  p_reason    text default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  s sessions%rowtype;
  o offerings%rowtype;
  v_shift interval;
  v_clash record;
  v_count int;
  v_what text;
  v_notified int := 0;
  v_teacher_user uuid;
  v_inst text;
begin
  select * into s from sessions where id = p_session;
  if not found then raise exception 'اللقاء غير موجود'; end if;
  select * into o from offerings where id = s.offering_id;
  if not is_offering_owner(o.id) then raise exception 'لا تملك صلاحية تعديل هذه الدورة'; end if;
  if p_scope not in ('one','following') then raise exception 'نطاق غير صحيح'; end if;
  if p_room is not null and o.institute_id is not null
     and not exists (select 1 from rooms where id = p_room and institute_id = o.institute_id) then
    raise exception 'القاعة لا تتبع هذا المعهد';
  end if;

  v_shift := p_starts_at - s.starts_at;

  drop table if exists _moved;
  create temp table _moved on commit drop as
    select x.id, x.seq, x.starts_at + v_shift as new_start, x.minutes, coalesce(p_room, x.room_id) as new_room
    from sessions x
    where x.offering_id = o.id and not x.cancelled
      and (x.id = s.id or (p_scope = 'following' and x.seq > s.seq));

  -- room clash with another offering's session
  select m.new_start, ox.title, r.name into v_clash
  from _moved m
  join sessions y on y.room_id = m.new_room and y.offering_id <> o.id and not y.cancelled
  join offerings ox on ox.id = y.offering_id
  join rooms r on r.id = m.new_room
  where tstzrange(y.starts_at, y.starts_at + make_interval(mins => y.minutes))
     && tstzrange(m.new_start, m.new_start + make_interval(mins => m.minutes))
  limit 1;
  if found then
    raise exception '% محجوزة يوم % لدورة «%». اختر قاعة أو ساعة أخرى.', v_clash.name, fmt_time(v_clash.new_start), v_clash.title;
  end if;

  -- course teacher clash
  if o.course_teacher_id is not null then
    select m.new_start into v_clash
    from _moved m
    join teacher_busy(o.course_teacher_id, m.new_start - interval '4 hours', m.new_start + interval '4 hours') b
      on tstzrange(b.starts_at, b.starts_at + make_interval(mins => b.minutes))
      && tstzrange(m.new_start, m.new_start + make_interval(mins => m.minutes))
    where not exists (select 1 from sessions z where z.offering_id = o.id and z.starts_at = b.starts_at)
    limit 1;
    if found then raise exception 'معلم الدورة مشغول يوم %. اختر ساعة أخرى.', fmt_time(v_clash.new_start); end if;
  end if;

  update sessions x set starts_at = m.new_start, room_id = m.new_room, changed = true
  from _moved m where x.id = m.id;
  get diagnostics v_count = row_count;

  v_what := case when v_count = 1
    then format('اللقاء %s من «%s» أصبح %s', s.seq, o.title, fmt_time(p_starts_at))
    else format('%s لقاءات من «%s» (من اللقاء %s) تغيّرت، أولها %s', v_count, o.title, s.seq, fmt_time(p_starts_at)) end
    || coalesce('، ' || (select name from rooms where id = coalesce(p_room, s.room_id)), '')
    || coalesce('. السبب: ' || nullif(trim(p_reason), ''), '');

  select coalesce(i.name, t.name) into v_inst
  from offerings oo left join institutes i on i.id = oo.institute_id left join teachers t on t.id = oo.teacher_id
  where oo.id = o.id;

  -- every booker (guardian or student account), once
  insert into notifications (user_id, kind, body, link)
  select distinct b.booked_by, 'schedule_changed', format('غيّر %s الموعد: %s', v_inst, v_what), '/schedule'
  from bookings b where b.offering_id = o.id and b.status in ('pending','confirmed');
  get diagnostics v_notified = row_count;

  -- the course teacher
  select t.user_id into v_teacher_user from teachers t where t.id = coalesce(o.course_teacher_id, o.teacher_id);
  if v_teacher_user is not null and v_teacher_user <> auth.uid() then
    insert into notifications (user_id, kind, body, link)
    values (v_teacher_user, 'schedule_changed', format('غيّر %s موعد دورتك: %s', v_inst, v_what), '/teach');
  end if;

  insert into change_log (offering_id, changed_by, body, notified_count)
  values (o.id, auth.uid(), v_what, v_notified + case when v_teacher_user is not null then 1 else 0 end);

  return v_count;
end $$;

-- ---------- row level security ----------
alter table public.profiles           enable row level security;
alter table public.children           enable row level security;
alter table public.subjects           enable row level security;
alter table public.levels             enable row level security;
alter table public.teachers           enable row level security;
alter table public.institutes         enable row level security;
alter table public.institute_teachers enable row level security;
alter table public.rooms              enable row level security;
alter table public.offerings          enable row level security;
alter table public.availability       enable row level security;
alter table public.sessions           enable row level security;
alter table public.bookings           enable row level security;
alter table public.attendance         enable row level security;
alter table public.notifications      enable row level security;
alter table public.change_log         enable row level security;
alter table public.reviews            enable row level security;

-- public catalogue
create policy "read subjects"    on public.subjects   for select using (true);
create policy "read levels"      on public.levels     for select using (true);
create policy "read teachers"    on public.teachers   for select using (verify = 'verified' or user_id = auth.uid());
create policy "read institutes"  on public.institutes for select using (verify = 'verified' or owner_id = auth.uid());
create policy "read inst teachers" on public.institute_teachers for select using (true);
create policy "read rooms"       on public.rooms      for select using (true);
create policy "read offerings"   on public.offerings  for select using (active or is_offering_owner(id));
create policy "read availability" on public.availability for select using (true);
create policy "read sessions"    on public.sessions   for select using (true);
create policy "read reviews"     on public.reviews    for select using (true);

-- own profile and children
create policy "own profile read"   on public.profiles for select using (id = auth.uid());
create policy "own profile update" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy "own children"       on public.children for all using (guardian_id = auth.uid()) with check (guardian_id = auth.uid());

-- teacher and institute manage their own records
create policy "teacher self insert" on public.teachers for insert with check (user_id = auth.uid());
create policy "teacher self update" on public.teachers for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "institute owner insert" on public.institutes for insert with check (owner_id = auth.uid());
create policy "institute owner update" on public.institutes for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "institute owner rooms" on public.rooms for all
  using (exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()))
  with check (exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()));
create policy "institute owner staff" on public.institute_teachers for all
  using (exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()))
  with check (exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()));

create policy "owner writes offerings" on public.offerings for insert with check (
  (teacher_id is not null and teacher_id = my_teacher_id())
  or (institute_id is not null and exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid())));
create policy "owner updates offerings" on public.offerings for update using (is_offering_owner(id)) with check (is_offering_owner(id));
create policy "owner deletes offerings" on public.offerings for delete using (is_offering_owner(id));

create policy "teacher availability" on public.availability for all
  using (teacher_id = my_teacher_id()) with check (teacher_id = my_teacher_id());

-- new sessions are added by the owner; changing a time goes through reschedule_session
create policy "owner adds sessions" on public.sessions for insert with check (is_offering_owner(offering_id));
create policy "owner deletes sessions" on public.sessions for delete using (is_offering_owner(offering_id));

-- bookings: the booker and the owner see them; writes only through functions
create policy "see bookings" on public.bookings for select
  using (booked_by = auth.uid() or is_offering_owner(offering_id));

create policy "owner attendance" on public.attendance for all
  using (exists (select 1 from sessions s where s.id = session_id and is_offering_owner(s.offering_id)))
  with check (exists (select 1 from sessions s where s.id = session_id and is_offering_owner(s.offering_id)));
create policy "booker sees attendance" on public.attendance for select
  using (exists (select 1 from bookings b where b.id = booking_id and b.booked_by = auth.uid()));

create policy "own notifications" on public.notifications for select using (user_id = auth.uid());
create policy "mark own notifications" on public.notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "owner reads change log" on public.change_log for select using (is_offering_owner(offering_id));

create policy "review own booking" on public.reviews for insert with check (
  exists (select 1 from bookings b where b.id = booking_id and b.booked_by = auth.uid() and b.status = 'confirmed'));

-- functions callable by signed-in users only
revoke execute on function public.create_booking, public.respond_booking, public.cancel_booking, public.reschedule_session from anon, public;
grant  execute on function public.create_booking, public.respond_booking, public.cancel_booking, public.reschedule_session to authenticated;
grant  execute on function public.teacher_busy, public.seats_taken to anon, authenticated;

-- ---------- fields only an admin may set ----------
create or replace function public.protect_admin_fields() returns trigger
language plpgsql as $$
begin
  if current_user in ('anon','authenticated') then
    if tg_op = 'INSERT' then
      new.verify := 'pending'; new.rating := 0; new.reviews_count := 0;
    else
      new.verify := old.verify; new.rating := old.rating; new.reviews_count := old.reviews_count;
    end if;
  end if;
  return new;
end $$;
create trigger teachers_protect before insert or update on public.teachers
  for each row execute function public.protect_admin_fields();
create trigger institutes_protect before insert or update on public.institutes
  for each row execute function public.protect_admin_fields();

create or replace function public.protect_profile_roles() returns trigger
language plpgsql as $$
begin
  if current_user in ('anon','authenticated') then
    if 'admin' = any(new.roles) and not 'admin' = any(old.roles) then
      new.roles := array_remove(new.roles, 'admin');
    end if;
    if new.active_role <> all(new.roles) then new.active_role := old.active_role; end if;
  end if;
  return new;
end $$;
create trigger profiles_protect before update on public.profiles
  for each row execute function public.protect_profile_roles();

-- A new teacher starts with Sunday-Thursday 15:00-21:00 free; they can change it.
create or replace function public.default_availability() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into availability (teacher_id, weekday, start_time, end_time)
  select new.id, w, '15:00', '21:00' from generate_series(0,4) w;
  return new;
end $$;
create trigger teachers_default_availability after insert on public.teachers
  for each row when (new.user_id is not null) execute function public.default_availability();

-- Seats taken for every group/course offering (counts only, no names).
create or replace function public.seats_overview()
returns table (offering_id uuid, session_id uuid, taken int)
language sql stable security definer set search_path = public as $$
  select b.offering_id, b.session_id, count(*)::int
  from bookings b join offerings o on o.id = b.offering_id
  where o.type in ('group','course') and b.status in ('pending','confirmed')
  group by b.offering_id, b.session_id
$$;

-- Bookings on the caller's own offerings, with the student's display name.
create or replace function public.owner_bookings(p_offering uuid default null)
returns table (
  booking_id uuid, offering_id uuid, offering_title text, offering_type public.offering_type,
  student_name text, starts_at timestamptz, session_id uuid, status public.booking_status,
  pay_method text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select b.id, o.id, o.title, o.type,
         coalesce(c.name, p.full_name, 'طالب'), coalesce(b.starts_at, s.starts_at), b.session_id,
         b.status, b.pay_method, b.created_at
  from bookings b
  join offerings o on o.id = b.offering_id
  left join children c on c.id = b.child_id
  left join profiles p on p.id = b.booked_by
  left join sessions s on s.id = b.session_id
  where is_offering_owner(o.id) and (p_offering is null or o.id = p_offering)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;

grant execute on function public.seats_overview, public.teacher_busy, public.seats_taken to anon, authenticated;
grant execute on function public.owner_bookings to authenticated;
revoke execute on function public.owner_bookings from anon, public;
