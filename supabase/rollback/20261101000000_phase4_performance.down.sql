-- Rollback of supabase/migrations/20261101000000_phase4_performance.sql (restores the phase 3 definitions).
-- Order: roll the APP back first (the phase 4 app calls search_offers, course_seats and owner_student_count).
-- Then this file. To go further back, apply the phase 3 down file afterwards.
begin;

-- 1. Read policy of offerings: phase 3 form (row-by-row owner check; same visibility)
drop policy if exists "read offerings" on public.offerings;
create policy "read offerings" on public.offerings for select
  using ((active and not moderation_hidden and offering_owner_verified(id))
         or (teacher_id is not null and teacher_id = my_teacher_id())
         or (institute_id is not null and exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()))
         or is_offering_owner(id) or is_admin()
         or exists (select 1 from bookings b where b.offering_id = offerings.id and b.booked_by = auth.uid()));

-- 2. Dashboards and conversations: phase 3 bodies (same results, slower at scale)
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

drop function if exists public.owner_money_summary();
create function public.owner_money_summary()
returns table (paid_month int, open_amount int, reported int)
language sql stable security definer set search_path = public as $$
  with mine as (select id from offerings where is_offering_owner(id))
  select
    coalesce((select sum(price) from bookings where offering_id in (select id from mine) and pay_status = 'paid'
               and paid_at >= date_trunc('month', now() at time zone 'Asia/Jerusalem') at time zone 'Asia/Jerusalem'), 0)::int
    + coalesce((select sum(price) from lesson_packages where offering_id in (select id from mine) and pay_status = 'paid'
               and paid_at >= date_trunc('month', now() at time zone 'Asia/Jerusalem') at time zone 'Asia/Jerusalem'), 0)::int,
    coalesce((select sum(price) from bookings b left join sessions s on s.id = b.session_id where b.offering_id in (select id from mine)
               and b.status = 'confirmed' and b.pay_status in ('unpaid','reported') and coalesce(b.starts_at, s.starts_at, b.created_at) <= now()), 0)::int
    + coalesce((select sum(price) from lesson_packages where offering_id in (select id from mine) and status <> 'cancelled' and pay_status in ('unpaid','reported')), 0)::int,
    ((select count(*) from bookings where offering_id in (select id from mine) and status = 'confirmed' and pay_status = 'reported')
     + (select count(*) from lesson_packages where offering_id in (select id from mine) and pay_status = 'reported'))::int
$$;

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

create or replace function public.owner_bookings(p_offering uuid default null, p_from timestamptz default null)
returns table (booking_id uuid, offering_id uuid, offering_title text, offering_type offering_type, student_name text, starts_at timestamptz,
               session_id uuid, status booking_status, pay_method text, created_at timestamptz, mode place_kind, weekly boolean, series_id uuid,
               series_count int, price int, pay_status text, installments_total int, installments_paid int, offline boolean, offline_phone text,
               can_link boolean)
language sql stable security definer set search_path = public as $$
  with mine as (
    select o.id from offerings o where o.teacher_id = my_teacher_id()
    union select o.id from offerings o where o.course_teacher_id = my_teacher_id()
    union select o.id from offerings o join institutes i on i.id = o.institute_id where i.owner_id = auth.uid()
  )
  select b.id, o.id, o.title, o.type,
         coalesce(c.name, b.offline_name, p.full_name, 'طالب'), coalesce(b.starts_at, s.starts_at), b.session_id,
         b.status, b.pay_method, b.created_at, b.mode, b.weekly, b.series_id,
         case when b.series_id is null then null
              else (select count(*)::int from bookings x where x.series_id = b.series_id and x.status in ('pending','confirmed')) end,
         b.price, b.pay_status, b.installments_total, b.installments_paid, b.booked_by is null, b.offline_phone,
         b.booked_by is null and b.offline_phone is not null and is_offering_owner(o.id)
  from mine
  join offerings o on o.id = mine.id
  join bookings b on b.offering_id = o.id
  left join children c on c.id = b.child_id
  left join profiles p on p.id = b.booked_by
  left join sessions s on s.id = b.session_id
  where (p_offering is null or o.id = p_offering)
    and (p_from is null or coalesce(b.starts_at, s.starts_at, b.created_at) >= p_from)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;

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

create or replace function public.my_header_counts()
returns table (notifications int, messages int)
language sql stable security definer set search_path = public as $$
  select
    (select count(*)::int from notifications n where n.user_id = auth.uid() and n.read_at is null and n.kind <> 'message'),
    (select count(*)::int from messages m join conversations c on c.id = m.conversation_id
      left join teachers t on t.id = c.teacher_id left join institutes i on i.id = c.institute_id
      where m.read_at is null and m.sender_id <> auth.uid()
        and (c.user_id = auth.uid() or coalesce(t.user_id, i.owner_id) = auth.uid()))
$$;

-- 3. New functions, helpers and indexes of phase 4
drop function if exists public.search_offers(text, text, int, int, text, text, int, int);
drop function if exists public.course_seats(uuid[], uuid);
drop function if exists public.owner_student_count();
drop function if exists public.my_conversation_ids();
drop function if exists app_private.public_teacher_ids();
drop function if exists app_private.public_institute_ids();
drop schema if exists app_private;
drop index if exists public.conversations_user, public.lesson_packages_offering;

-- 4. Least privilege: owner_money_summary was re-created
revoke execute on function public.owner_money_summary() from public, anon;
grant execute on function public.owner_money_summary() to authenticated;

commit;
