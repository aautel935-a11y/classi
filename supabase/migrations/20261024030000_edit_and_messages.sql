-- Classi: editing offers, and messaging between families and teachers/institutes.

-- ================= editing offers =================
-- Each booking keeps the price agreed when it was made, so a later price
-- change never alters an existing booking.
alter table public.bookings add column if not exists price int;
update public.bookings b set price = o.price from public.offerings o where o.id = b.offering_id and b.price is null;

create or replace function public.bookings_set_price() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.price is null then select price into new.price from offerings where id = new.offering_id; end if;
  return new;
end $$;
drop trigger if exists bookings_price on public.bookings;
create trigger bookings_price before insert on public.bookings
  for each row execute function public.bookings_set_price();

-- Seats can't drop below what is already booked; owner and type can't change.
create or replace function public.offerings_guard_edit() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_taken int;
begin
  if new.teacher_id is distinct from old.teacher_id or new.institute_id is distinct from old.institute_id then
    raise exception 'لا يمكن نقل العرض إلى حساب آخر';
  end if;
  if new.type <> old.type then raise exception 'لا يمكن تغيير نوع العرض. أنشئ عرضاً جديداً.'; end if;
  if new.seats is not null and new.seats is distinct from old.seats then
    select coalesce(max(c), 0) into v_taken from (
      select count(*) c from bookings where offering_id = new.id and status in ('pending','confirmed')
      group by coalesce(session_id, '00000000-0000-0000-0000-000000000000'::uuid)) x;
    if new.seats < v_taken then
      raise exception 'يوجد % حجوزات. لا يمكن أن يكون عدد المقاعد أقل من ذلك.', v_taken;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists offerings_guard on public.offerings;
create trigger offerings_guard before update on public.offerings
  for each row execute function public.offerings_guard_edit();

-- ================= messaging =================
-- One conversation per family account and teacher (or institute).
create table if not exists public.conversations (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id) on delete cascade,   -- the family / student side
  teacher_id      uuid references public.teachers(id) on delete cascade,
  institute_id    uuid references public.institutes(id) on delete cascade,
  created_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  constraint one_side check ((teacher_id is null) <> (institute_id is null))
);
create unique index if not exists conversations_user_teacher on public.conversations (user_id, teacher_id) where teacher_id is not null;
create unique index if not exists conversations_user_institute on public.conversations (user_id, institute_id) where institute_id is not null;

create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body            text not null check (length(trim(body)) between 1 and 2000),
  created_at      timestamptz not null default now(),
  read_at         timestamptz
);
create index if not exists messages_conv on public.messages (conversation_id, created_at);

create table if not exists public.conversation_reports (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  reporter_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  reason          text,
  created_at      timestamptz not null default now(),
  resolved        boolean not null default false
);

-- The account on the teacher/institute side.
create or replace function public.conversation_owner(p_conv uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(t.user_id, i.owner_id)
  from conversations c
  left join teachers t on t.id = c.teacher_id
  left join institutes i on i.id = c.institute_id
  where c.id = p_conv
$$;

create or replace function public.is_conversation_member(p_conv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversations c where c.id = p_conv
                 and (c.user_id = auth.uid() or conversation_owner(c.id) = auth.uid()))
$$;

create or replace function public.is_conversation_reported(p_conv uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversation_reports r where r.conversation_id = p_conv)
$$;

alter table public.conversations        enable row level security;
alter table public.messages             enable row level security;
alter table public.conversation_reports enable row level security;

create policy "members read conversations" on public.conversations for select
  using (is_conversation_member(id) or (is_admin() and is_conversation_reported(id)));
create policy "members read messages" on public.messages for select
  using (is_conversation_member(conversation_id) or (is_admin() and is_conversation_reported(conversation_id)));
create policy "members send messages" on public.messages for insert
  with check (sender_id = auth.uid() and is_conversation_member(conversation_id));
create policy "report own conversation" on public.conversation_reports for insert
  with check (reporter_id = auth.uid() and is_conversation_member(conversation_id));
create policy "admin reads reports" on public.conversation_reports for select using (is_admin() or reporter_id = auth.uid());
create policy "admin resolves reports" on public.conversation_reports for update using (is_admin()) with check (is_admin());

grant select on public.conversations to authenticated;
grant select, insert on public.messages to authenticated;
grant select, insert, update on public.conversation_reports to authenticated;

-- A family starts (or reopens) a conversation with a verified teacher or institute.
create or replace function public.start_conversation(p_teacher uuid default null, p_institute uuid default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_owner uuid;
begin
  if auth.uid() is null then raise exception 'سجّل الدخول أولاً'; end if;
  if (p_teacher is null) = (p_institute is null) then raise exception 'اختر معلماً أو معهداً'; end if;
  if p_teacher is not null then
    select user_id into v_owner from teachers where id = p_teacher and verify = 'verified';
  else
    select owner_id into v_owner from institutes where id = p_institute and verify = 'verified';
  end if;
  if v_owner is null then raise exception 'لا يمكن مراسلة هذا الحساب بعد'; end if;
  if v_owner = auth.uid() then raise exception 'لا يمكنك مراسلة نفسك'; end if;
  select id into v_id from conversations
   where user_id = auth.uid() and teacher_id is not distinct from p_teacher and institute_id is not distinct from p_institute;
  if v_id is null then
    insert into conversations (user_id, teacher_id, institute_id) values (auth.uid(), p_teacher, p_institute) returning id into v_id;
  end if;
  return v_id;
end $$;

-- A teacher/institute opens a conversation with whoever made a booking.
create or replace function public.start_conversation_for_booking(p_booking uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; o offerings%rowtype; v_id uuid;
begin
  select * into b from bookings where id = p_booking;
  if not found or not is_offering_owner(b.offering_id) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  select * into o from offerings where id = b.offering_id;
  select id into v_id from conversations
   where user_id = b.booked_by and teacher_id is not distinct from o.teacher_id and institute_id is not distinct from o.institute_id;
  if v_id is null then
    insert into conversations (user_id, teacher_id, institute_id) values (b.booked_by, o.teacher_id, o.institute_id) returning id into v_id;
  end if;
  return v_id;
end $$;

-- Inbox: one row per conversation, with the other side's name and the unread count.
create or replace function public.my_conversations()
returns table (id uuid, other_name text, other_photo text, other_kind text, last_body text, last_at timestamptz, unread int, i_am_owner boolean)
language sql stable security definer set search_path = public as $$
  select c.id,
         case when c.user_id = auth.uid() then coalesce(t.name, i.name) else coalesce(p.full_name, 'ولي أمر') end,
         case when c.user_id = auth.uid() then coalesce(t.photo_url, i.logo_url) else p.avatar_url end,
         case when c.user_id = auth.uid() then (case when t.id is not null then 'teacher' else 'institute' end) else 'family' end,
         (select m.body from messages m where m.conversation_id = c.id order by m.created_at desc limit 1),
         c.last_message_at,
         (select count(*)::int from messages m where m.conversation_id = c.id and m.sender_id <> auth.uid() and m.read_at is null),
         c.user_id <> auth.uid()
  from conversations c
  left join teachers t on t.id = c.teacher_id
  left join institutes i on i.id = c.institute_id
  left join profiles p on p.id = c.user_id
  where c.user_id = auth.uid() or coalesce(t.user_id, i.owner_id) = auth.uid()
  order by c.last_message_at desc
$$;

create or replace function public.mark_conversation_read(p_conv uuid) returns void
language sql security definer set search_path = public as $$
  update messages set read_at = now()
   where conversation_id = p_conv and sender_id <> auth.uid() and read_at is null and is_conversation_member(p_conv);
  update notifications set read_at = now()
   where user_id = auth.uid() and kind = 'message' and link = '/messages/' || p_conv and read_at is null;
$$;

-- New message: bump the conversation, tell the other side (one unread notice per conversation).
create or replace function public.on_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare c conversations%rowtype; v_to uuid; v_from text;
begin
  select * into c from conversations where id = new.conversation_id;
  update conversations set last_message_at = new.created_at where id = c.id;
  v_to := case when new.sender_id = c.user_id then conversation_owner(c.id) else c.user_id end;
  if v_to is null then return new; end if;
  select case when new.sender_id = c.user_id then coalesce(p.full_name, 'ولي أمر')
              else coalesce((select name from teachers where id = c.teacher_id), (select name from institutes where id = c.institute_id)) end
    into v_from from profiles p where p.id = c.user_id;
  delete from notifications where user_id = v_to and kind = 'message' and link = '/messages/' || c.id and read_at is null;
  insert into notifications (user_id, kind, body, link)
  values (v_to, 'message', format('رسالة جديدة من %s: %s', v_from, left(new.body, 80)), '/messages/' || c.id);
  return new;
end $$;
drop trigger if exists messages_after_insert on public.messages;
create trigger messages_after_insert after insert on public.messages
  for each row execute function public.on_message();

-- Report: admins get a notice and can then read that conversation.
create or replace function public.on_report() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into notifications (user_id, kind, body, link)
  select p.id, 'report', 'بلاغ جديد عن محادثة. افتح لوحة الإدارة للمراجعة.', '/admin'
  from profiles p where 'admin' = any(p.roles);
  return new;
end $$;
drop trigger if exists reports_after_insert on public.conversation_reports;
create trigger reports_after_insert after insert on public.conversation_reports
  for each row execute function public.on_report();

revoke execute on function public.start_conversation, public.start_conversation_for_booking, public.my_conversations, public.mark_conversation_read from anon, public;
grant execute on function public.start_conversation, public.start_conversation_for_booking, public.my_conversations, public.mark_conversation_read, public.is_conversation_member to authenticated;
