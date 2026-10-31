-- Classi phase 4: performance at growth size, without changing who sees what or what the functions return.
-- Measured with supabase/tests/perf_data.sql (20,000 accounts, 3,000 offers, 200,000 bookings, 300,000 messages)
-- and supabase/tests/perf4_queries.sql; equivalence with perf4_visibility.sql and perf4_results.sql.
-- Safe on a live database: function bodies, one read policy, new helper functions. No data changes.

------------------------------------------------------------------------------------------------------------
-- 0. Helpers outside the API schema (PostgREST exposes only "public"): which teachers and institutes may
-- show offers to the public. Same conditions as offering_owner_verified, computed once per query.
------------------------------------------------------------------------------------------------------------
create schema if not exists app_private;
revoke all on schema app_private from public;
grant usage on schema app_private to anon, authenticated;

create or replace function app_private.public_teacher_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select t.id from teachers t
   where t.verify = 'verified' and not t.moderation_hidden and (t.user_id is null or is_active_user(t.user_id)) and owner_has_access(t.id, null)
$$;
create or replace function app_private.public_institute_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select i.id from institutes i
   where i.verify = 'verified' and not i.moderation_hidden and (i.owner_id is null or is_active_user(i.owner_id)) and owner_has_access(null, i.id)
$$;
revoke execute on function app_private.public_teacher_ids(), app_private.public_institute_ids() from public;
grant execute on function app_private.public_teacher_ids(), app_private.public_institute_ids() to anon, authenticated;

------------------------------------------------------------------------------------------------------------
-- 1. Read policy of offerings: the public branch looked up every offer's owner one row at a time
-- (offering_owner_verified). Same rule, evaluated as one set: 295 ms -> see PHASE-4.md for 2,889 visible offers.
-- The owner, admin and "I booked it" branches are unchanged.
------------------------------------------------------------------------------------------------------------
drop policy if exists "read offerings" on public.offerings;
create policy "read offerings" on public.offerings for select
  using ((active and not moderation_hidden and review_status = 'approved'
          and case when teacher_id is not null then teacher_id in (select app_private.public_teacher_ids())
                   when institute_id is not null then institute_id in (select app_private.public_institute_ids())
                   else false end)
         or (teacher_id is not null and teacher_id = my_teacher_id())
         or (institute_id is not null and exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()))
         or is_offering_owner(id) or is_admin()
         or exists (select 1 from bookings b where b.offering_id = offerings.id and b.booked_by = auth.uid()));

------------------------------------------------------------------------------------------------------------
-- 2. Search in the database, one page at a time (the whole catalogue no longer travels to the app, and the
-- 1,000-row API limit no longer cuts it). Same rules as the page's filter: type, place, subject, level, owner's
-- town, and a case-sensitive substring of the title, owner name or subject name. Same order (oldest first).
-- Runs with the caller's rights, so row security decides visibility exactly as before.
------------------------------------------------------------------------------------------------------------
create or replace function public.search_offers(p_type text default null, p_place text default null, p_subject int default null,
  p_level int default null, p_town text default null, p_q text default null, p_limit int default 30, p_offset int default 0)
returns table (id uuid, total bigint)
language sql stable security invoker as $$   -- no SET clause: lets the planner inline it with the real arguments
  -- The visible catalogue is assembled first, without the filters (row security applies to each table once and
  -- the joins are hashed); the filters then run over that list. Written so, the plan stays fast whatever the
  -- arguments (a prepared, generic plan once took 3 s by re-checking owners per offer).
  with t as materialized (select id, name, town from public.teachers),
       i as materialized (select id, name, town from public.institutes),
       v as materialized (
         select o.id, o.created_at, o.type::text as type, o.places::text[] as places, o.subject_id, o.level_id, o.title,
                coalesce(case when t.id is not null then t.name end, i.name) as owner_name,
                coalesce(case when t.id is not null then t.town end, i.town) as owner_town,
                coalesce(s.name, '') as subject_name
           from public.offerings o
           left join t on t.id = o.teacher_id
           left join i on i.id = o.institute_id
           left join public.subjects s on s.id = o.subject_id
          where o.active and (t.id is not null or i.id is not null))
  select v.id, count(*) over ()
    from v
   where (p_type is null or v.type = p_type)
     and (p_place is null or p_place = any (v.places))
     and (p_subject is null or v.subject_id = p_subject)
     and (p_level is null or v.level_id = p_level)
     and (p_town is null or v.owner_town = p_town)
     and (coalesce(p_q, '') = '' or strpos(v.title, p_q) > 0 or strpos(v.owner_name, p_q) > 0 or strpos(v.subject_name, p_q) > 0)
   order by v.created_at, v.id
   limit least(greatest(coalesce(p_limit, 30), 1), 100) offset greatest(coalesce(p_offset, 0), 0)
$$;

------------------------------------------------------------------------------------------------------------
-- 3. Seats taken in courses (bookings without a meeting), one row per offer: replaces the platform-wide
-- seats_overview() on the home page, search, the institute page and the institute dashboard.
------------------------------------------------------------------------------------------------------------
create or replace function public.course_seats(p_offerings uuid[] default null, p_institute uuid default null)
returns table (offering_id uuid, taken int)
language sql stable security definer set search_path = public as $$
  select b.offering_id, count(*)::int
    from bookings b join offerings o on o.id = b.offering_id
   where o.type in ('group','course') and b.status in ('pending','confirmed') and b.session_id is null
     and (p_offerings is null or b.offering_id = any (p_offerings))
     and (p_institute is null or o.institute_id = p_institute)
   group by b.offering_id
$$;

------------------------------------------------------------------------------------------------------------
-- 4. Owner dashboards: start from the caller's own offers (indexes) instead of testing every booking,
-- waitlist entry or offer on the platform. Same columns, same rows (perf4_results.sql fingerprints).
------------------------------------------------------------------------------------------------------------
create or replace function public.owner_payments()
returns table (kind text, id uuid, offering_id uuid, title text, who text, amount int, pay_method text, pay_status text, lesson_at timestamptz,
               reported_at timestamptz, installments_total int, installments_paid int)
language sql stable security definer set search_path = public as $$
  with mine as (
    select o.id from offerings o where o.teacher_id = my_teacher_id()
    union select o.id from offerings o join institutes i on i.id = o.institute_id where i.owner_id = auth.uid()
  )
  select 'booking', b.id, o.id, o.title, coalesce(c.name, b.offline_name, p.full_name, 'طالب'),
         installment_amount(b.price, b.installments_total, b.installments_paid), b.pay_method, b.pay_status,
         coalesce(b.starts_at, s.starts_at), b.reported_at, b.installments_total, b.installments_paid
    from mine join offerings o on o.id = mine.id
    join bookings b on b.offering_id = o.id
    left join sessions s on s.id = b.session_id
    left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
   where b.status = 'confirmed'
     and (b.pay_status = 'reported' or (b.pay_status = 'unpaid' and coalesce(b.starts_at, s.starts_at, b.created_at) <= now() + interval '1 day'))
  union all
  select 'package', k.id, o.id, o.title || ' · رزمة ' || k.size || ' حصص', coalesce(c.name, p.full_name, 'طالب'), k.price, k.pay_method, k.pay_status,
         k.created_at, k.reported_at, 1, 0
    from mine join offerings o on o.id = mine.id
    join lesson_packages k on k.offering_id = o.id
    left join children c on c.id = k.child_id left join profiles p on p.id = k.user_id
   where k.status <> 'cancelled' and k.pay_status in ('unpaid','reported')
  order by 8 desc, 9 desc
$$;

create index if not exists lesson_packages_offering on public.lesson_packages (offering_id);

create or replace function public.owner_money_summary()
returns table (paid_month int, open_amount int, reported int)
language plpgsql stable security definer set search_path = public as $$
declare
  -- The caller's own offers first (a short list), then the sums over their bookings and packages by index.
  v_ids uuid[] := array(select o.id from offerings o where o.teacher_id = my_teacher_id()
                        union select o.id from offerings o join institutes i on i.id = o.institute_id where i.owner_id = auth.uid());
  v_month timestamptz := date_trunc('month', now() at time zone 'Asia/Jerusalem') at time zone 'Asia/Jerusalem';
begin
  return query select
    coalesce((select sum(price) from bookings where offering_id = any (v_ids) and pay_status = 'paid' and paid_at >= v_month), 0)::int
    + coalesce((select sum(price) from lesson_packages where offering_id = any (v_ids) and pay_status = 'paid' and paid_at >= v_month), 0)::int,
    coalesce((select sum(price) from bookings b left join sessions s on s.id = b.session_id where b.offering_id = any (v_ids)
               and b.status = 'confirmed' and b.pay_status in ('unpaid','reported') and coalesce(b.starts_at, s.starts_at, b.created_at) <= now()), 0)::int
    + coalesce((select sum(price) from lesson_packages where offering_id = any (v_ids) and status <> 'cancelled' and pay_status in ('unpaid','reported')), 0)::int,
    ((select count(*) from bookings where offering_id = any (v_ids) and status = 'confirmed' and pay_status = 'reported')
     + (select count(*) from lesson_packages where offering_id = any (v_ids) and pay_status = 'reported'))::int;
end $$;

create or replace function public.owner_waitlist(p_offering uuid default null)
returns table (id uuid, offering_id uuid, offering_title text, offering_type public.offering_type,
               student_name text, note text, status text, pos int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  with mine as (
    select o.id from offerings o where o.teacher_id = my_teacher_id()
    union select o.id from offerings o where o.course_teacher_id = my_teacher_id()
    union select o.id from offerings o join institutes i on i.id = o.institute_id where i.owner_id = auth.uid()
  )
  select w.id, o.id, o.title, o.type, coalesce(c.name, p.full_name, 'طالب'), w.note, w.status,
         waitlist_position(w.id), w.created_at
  from mine
  join offerings o on o.id = mine.id
  join waitlist w on w.offering_id = o.id
  left join children c on c.id = w.child_id
  left join profiles p on p.id = w.user_id
  where (p_offering is null or o.id = p_offering)
    and w.status in ('waiting','notified')
  order by o.title, w.created_at
$$;

-- The teacher dashboard asks only for lessons from today on (plus every open request, whatever its date);
-- the "students" figure keeps counting all confirmed bookings through owner_student_count.
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
    and (p_from is null or b.status = 'pending' or coalesce(b.starts_at, s.starts_at, b.created_at) >= p_from)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;

create or replace function public.owner_student_count() returns int
language sql stable security definer set search_path = public as $$
  select count(distinct student_name)::int from owner_bookings() where status = 'confirmed'
$$;

------------------------------------------------------------------------------------------------------------
-- 5. Conversations and the header badge: the caller's conversations come from three indexed lookups instead of
-- a scan of every conversation (and every unread message) on the platform.
------------------------------------------------------------------------------------------------------------
create index if not exists conversations_user on public.conversations (user_id);

create or replace function public.my_conversation_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select c.id from conversations c where c.user_id = auth.uid()
  union select c.id from conversations c where c.teacher_id = my_teacher_id()
  union select c.id from conversations c join institutes i on i.id = c.institute_id where i.owner_id = auth.uid()
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
  where c.id in (select my_conversation_ids())
  order by c.last_message_at desc
$$;

create or replace function public.my_header_counts()
returns table (notifications int, messages int)
language sql stable security definer set search_path = public as $$
  select
    (select count(*)::int from notifications n where n.user_id = auth.uid() and n.read_at is null and n.kind <> 'message'),
    (select count(*)::int from messages m
      where m.conversation_id in (select my_conversation_ids()) and m.read_at is null and m.sender_id <> auth.uid())
$$;

------------------------------------------------------------------------------------------------------------
-- Least privilege (phase 1 allow-list): new functions get exactly the callers that need them.
------------------------------------------------------------------------------------------------------------
revoke execute on function public.search_offers(text, text, int, int, text, text, int, int), public.course_seats(uuid[], uuid),
  public.owner_student_count(), public.my_conversation_ids() from public, anon, authenticated;
grant execute on function public.search_offers(text, text, int, int, text, text, int, int), public.course_seats(uuid[], uuid) to anon, authenticated;
grant execute on function public.owner_student_count() to authenticated;
-- owner_money_summary changed language (create or replace keeps its grants; restated so a fresh build matches)
revoke execute on function public.owner_money_summary() from public, anon;
grant execute on function public.owner_money_summary() to authenticated;
-- my_conversation_ids is only used inside the two functions above (security definer): no direct callers.
