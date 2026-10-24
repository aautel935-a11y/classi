-- Classi: waiting list for full offers (full course, full group meetings, teacher with no free hours).
-- Students join, the teacher or institute sees the list in order and answers;
-- a freed seat, extra seats or new hours notify whoever is first in line.

create table if not exists public.waitlist (
  id          uuid primary key default gen_random_uuid(),
  offering_id uuid not null references public.offerings(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  child_id    uuid references public.children(id) on delete cascade,
  note        text check (char_length(note) <= 300),
  -- waiting: in line · notified: told a place opened · accepted: the teacher answered yes
  -- booked: has a booking now · declined: the teacher said no · left: the student left the list
  status      text not null default 'waiting' check (status in ('waiting','notified','accepted','booked','declined','left')),
  reply       text check (char_length(reply) <= 300),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists waitlist_one_open
  on public.waitlist (offering_id, user_id, coalesce(child_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status in ('waiting','notified');
create index if not exists waitlist_line on public.waitlist (offering_id, created_at) where status in ('waiting','notified');

alter table public.waitlist enable row level security;
create policy "see own or staff waitlist" on public.waitlist for select
  using (user_id = auth.uid() or is_offering_staff(offering_id) or is_admin());
grant select on public.waitlist to authenticated;

-- Place in line (1 = first) among people still waiting.
create or replace function public.waitlist_position(p_id uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from waitlist w, waitlist me
   where me.id = p_id and w.offering_id = me.offering_id
     and w.status in ('waiting','notified') and w.created_at <= me.created_at
$$;

-- Tell the first p_count people waiting that a place opened.
create or replace function public.waitlist_notify_next(p_offering uuid, p_count int default 1, p_why text default 'seat')
returns int
language plpgsql security definer set search_path = public as $$
declare w record; v_title text; v_n int := 0;
begin
  select title into v_title from offerings where id = p_offering;
  for w in select * from waitlist where offering_id = p_offering and status = 'waiting'
            order by created_at limit greatest(p_count, 0) loop
    update waitlist set status = 'notified', updated_at = now() where id = w.id;
    insert into notifications (user_id, kind, body, link) values (
      w.user_id, 'waitlist_open',
      case p_why when 'hours' then format('أضاف المعلم أوقاتاً جديدة: %s. احجز الآن قبل أن تمتلئ.', v_title)
                 else format('تحرّر مكان في %s. أنت الأول في قائمة الانتظار، احجز الآن.', v_title) end,
      '/offer/' || p_offering);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ================= student side =================
create or replace function public.join_waitlist(p_offering uuid, p_child uuid default null, p_note text default null)
returns int
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_id uuid; v_pos int; v_owner uuid; v_who text;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if not is_active_user() then raise exception 'حسابك موقوف حالياً'; end if;
  select * into o from offerings where id = p_offering and active and not moderation_hidden;
  if not found or not offering_owner_verified(o.id) then raise exception 'هذا العرض غير متاح'; end if;
  if o.type = 'recorded' then raise exception 'المحتوى المسجّل لا يمتلئ، يمكنك شراؤه مباشرة'; end if;
  if is_offering_owner(o.id) then raise exception 'هذا عرضك أنت'; end if;
  if p_child is not null and not exists (select 1 from children where id = p_child and guardian_id = auth.uid()) then
    raise exception 'هذا الطالب غير مرتبط بحسابك';
  end if;
  if o.type = 'course' and exists (select 1 from bookings where offering_id = o.id and booked_by = auth.uid()
       and child_id is not distinct from p_child and status in ('pending','confirmed')) then
    raise exception 'أنت مسجّل في هذه الدورة بالفعل';
  end if;
  if exists (select 1 from waitlist where offering_id = o.id and user_id = auth.uid()
               and child_id is not distinct from p_child and status in ('waiting','notified')) then
    raise exception 'أنت في قائمة الانتظار بالفعل';
  end if;

  insert into waitlist (offering_id, user_id, child_id, note)
  values (o.id, auth.uid(), p_child, nullif(trim(p_note), ''))
  returning id into v_id;
  v_pos := waitlist_position(v_id);

  v_owner := offering_owner_user(o.id);
  select coalesce((select name from children where id = p_child), (select full_name from profiles where id = auth.uid())) into v_who;
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (
      v_owner, 'waitlist_join',
      format('%s ينتظر مكاناً في %s (%s في قائمة الانتظار)', coalesce(v_who, 'طالب'), o.title, v_pos),
      '/manage/course/' || o.id || '#waitlist');
  end if;
  return v_pos;
end $$;

create or replace function public.leave_waitlist(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update waitlist set status = 'left', updated_at = now()
   where id = p_id and user_id = auth.uid() and status in ('waiting','notified','accepted');
  if not found then raise exception 'لست في قائمة الانتظار'; end if;
end $$;

-- The current user's open places in line, with position.
create or replace function public.my_waitlist()
returns table (id uuid, offering_id uuid, offering_title text, offering_type public.offering_type,
               owner_name text, child_name text, status text, reply text, pos int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select w.id, o.id, o.title, o.type, coalesce(t.name, i.name), c.name, w.status, w.reply,
         case when w.status in ('waiting','notified') then waitlist_position(w.id) end, w.created_at
  from waitlist w
  join offerings o on o.id = w.offering_id
  left join teachers t on t.id = o.teacher_id
  left join institutes i on i.id = o.institute_id
  left join children c on c.id = w.child_id
  where w.user_id = auth.uid()
    and (w.status in ('waiting','notified','accepted') or (w.status = 'declined' and w.updated_at > now() - interval '14 days'))
  order by w.created_at
$$;

-- ================= teacher / institute side =================
create or replace function public.owner_waitlist(p_offering uuid default null)
returns table (id uuid, offering_id uuid, offering_title text, offering_type public.offering_type,
               student_name text, note text, status text, pos int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select w.id, o.id, o.title, o.type, coalesce(c.name, p.full_name, 'طالب'), w.note, w.status,
         waitlist_position(w.id), w.created_at
  from waitlist w
  join offerings o on o.id = w.offering_id
  left join children c on c.id = w.child_id
  left join profiles p on p.id = w.user_id
  where is_offering_staff(o.id) and (p_offering is null or o.id = p_offering)
    and w.status in ('waiting','notified')
  order by o.title, w.created_at
$$;

-- Answer someone in line.
--  accept, course  → registered (an extra seat the owner chose to open)
--  accept, group   → a seat in the next meeting
--  accept, private → a conversation opens to agree on a time; returns its id
--  decline         → they are told, with the optional reply
create or replace function public.respond_waitlist(p_id uuid, p_accept boolean, p_reply text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare w waitlist%rowtype; o offerings%rowtype; v_session uuid; v_at timestamptz; v_conv uuid; v_reply text;
begin
  select * into w from waitlist where id = p_id;
  if not found or not is_offering_owner(w.offering_id) then raise exception 'لا تملك صلاحية على هذه القائمة'; end if;
  if w.status not in ('waiting','notified') then raise exception 'تم الرد على هذا الطلب سابقاً'; end if;
  select * into o from offerings where id = w.offering_id;
  v_reply := nullif(trim(p_reply), '');

  if not p_accept then
    update waitlist set status = 'declined', reply = v_reply, updated_at = now() where id = p_id;
    insert into notifications (user_id, kind, body, link) values (
      w.user_id, 'waitlist_answer',
      format('اعتذر %s عن %s.%s', case when o.institute_id is not null then 'المعهد' else 'المعلم' end, o.title,
             coalesce(' ' || v_reply, ' جرّب عرضاً آخر أو موعداً لاحقاً.')),
      '/search');
    return null;
  end if;

  if o.type = 'course' then
    insert into bookings (offering_id, booked_by, child_id, minutes, status, pay_method, mode, price)
    values (o.id, w.user_id, w.child_id, o.minutes, 'confirmed', 'bit', o.places[1], o.price);
    update waitlist set status = 'booked', reply = v_reply, updated_at = now() where id = p_id;
    insert into notifications (user_id, kind, body, link)
    values (w.user_id, 'waitlist_answer', format('فُتح لك مقعد! تم تسجيلك في %s.%s', o.title, coalesce(' ' || v_reply, '')), '/schedule');
  elsif o.type = 'group' then
    select id, starts_at into v_session, v_at from sessions
     where offering_id = o.id and not cancelled and starts_at > now()
       and not exists (select 1 from bookings b where b.session_id = sessions.id and b.booked_by = w.user_id
                         and b.child_id is not distinct from w.child_id and b.status in ('pending','confirmed'))
     order by starts_at limit 1;
    if v_session is null then raise exception 'لا لقاءات قادمة لهذه المجموعة. أضف لقاءً أولاً.'; end if;
    insert into bookings (offering_id, session_id, booked_by, child_id, minutes, status, pay_method, mode, price)
    values (o.id, v_session, w.user_id, w.child_id, o.minutes, 'confirmed', 'bit', o.places[1], o.price);
    update waitlist set status = 'booked', reply = v_reply, updated_at = now() where id = p_id;
    insert into notifications (user_id, kind, body, link)
    values (w.user_id, 'waitlist_answer', format('فُتح لك مقعد في %s، لقاء %s.%s', o.title, fmt_time(v_at), coalesce(' ' || v_reply, '')), '/schedule');
  else
    select id into v_conv from conversations
     where user_id = w.user_id and teacher_id is not distinct from o.teacher_id and institute_id is not distinct from o.institute_id;
    if v_conv is null then
      insert into conversations (user_id, teacher_id, institute_id) values (w.user_id, o.teacher_id, o.institute_id) returning id into v_conv;
    end if;
    if v_reply is not null then
      insert into messages (conversation_id, sender_id, body) values (v_conv, auth.uid(), v_reply);
    end if;
    update waitlist set status = 'accepted', reply = v_reply, updated_at = now() where id = p_id;
    insert into notifications (user_id, kind, body, link)
    values (w.user_id, 'waitlist_answer', format('ردّ المعلم على طلب الانتظار لـ %s. راسله لتتفقا على موعد.', o.title), '/messages/' || v_conv);
  end if;
  return v_conv;
end $$;

-- A teacher who saves new hours tells everyone waiting for their private lessons.
create or replace function public.waitlist_hours_opened() returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0;
begin
  for r in select o.id, count(w.*) n from offerings o join teachers t on t.id = o.teacher_id
            join waitlist w on w.offering_id = o.id and w.status = 'waiting'
           where t.user_id = auth.uid() and o.type = 'private' group by o.id loop
    v_n := v_n + waitlist_notify_next(r.id, r.n::int, 'hours');
  end loop;
  return v_n;
end $$;

-- ================= automatic notifications =================
-- A cancelled or declined seat in a group or course goes to the first person waiting.
create or replace function public.waitlist_on_booking() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_type offering_type;
begin
  select type into v_type from offerings where id = new.offering_id;
  if tg_op = 'INSERT' then
    if new.status in ('pending','confirmed') then
      update waitlist set status = 'booked', updated_at = now()
       where offering_id = new.offering_id and user_id = new.booked_by
         and child_id is not distinct from new.child_id and status in ('waiting','notified','accepted');
    end if;
  elsif old.status in ('pending','confirmed') and new.status not in ('pending','confirmed')
        and v_type in ('group','course')
        and coalesce(new.starts_at, (select starts_at from sessions where id = new.session_id), now() + interval '1 day') > now() then
    perform waitlist_notify_next(new.offering_id, 1, 'seat');
  end if;
  return new;
end $$;
drop trigger if exists waitlist_on_booking on public.bookings;
create trigger waitlist_on_booking after insert or update of status on public.bookings
  for each row execute function public.waitlist_on_booking();

-- More seats on an offer → that many people in line hear about it.
create or replace function public.waitlist_on_seats() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.seats is not null and old.seats is not null and new.seats > old.seats then
    perform waitlist_notify_next(new.id, new.seats - old.seats, 'seat');
  end if;
  return new;
end $$;
drop trigger if exists waitlist_on_seats on public.offerings;
create trigger waitlist_on_seats after update of seats on public.offerings
  for each row execute function public.waitlist_on_seats();

revoke execute on function public.join_waitlist, public.leave_waitlist, public.my_waitlist, public.owner_waitlist,
  public.respond_waitlist, public.waitlist_hours_opened, public.waitlist_notify_next, public.waitlist_position from anon, public;
grant execute on function public.join_waitlist, public.leave_waitlist, public.my_waitlist, public.owner_waitlist,
  public.respond_waitlist, public.waitlist_hours_opened to authenticated;
