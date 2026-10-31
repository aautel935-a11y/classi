-- Classi phase 3: indexes for the hot filters (measured with supabase/tests/perf_check.sql), lighter header
-- counts / owner bookings / seat counts, and admin-editable booking and SMS limits.
-- Safe on a live database: indexes and function bodies only; signatures keep every old call working.

------------------------------------------------------------------------------------------------------------
-- 1. Indexes (SCALE-01). Small tables today; created without CONCURRENTLY because migrations run in a transaction.
------------------------------------------------------------------------------------------------------------
create index if not exists bookings_live_starts on public.bookings (starts_at) where status in ('pending','confirmed');
create index if not exists bookings_session on public.bookings (session_id) where session_id is not null;
create index if not exists sessions_offering_starts on public.sessions (offering_id, starts_at);
create index if not exists availability_teacher_day on public.availability (teacher_id, weekday);
create index if not exists offerings_course_teacher on public.offerings (course_teacher_id) where course_teacher_id is not null;
create index if not exists children_guardian on public.children (guardian_id);
create index if not exists institutes_owner on public.institutes (owner_id);
create index if not exists reviews_teacher_recent on public.reviews (teacher_id, created_at desc) where teacher_id is not null;
create index if not exists reviews_institute_recent on public.reviews (institute_id, created_at desc) where institute_id is not null;
create index if not exists messages_unread on public.messages (conversation_id) where read_at is null;
create index if not exists conversations_teacher on public.conversations (teacher_id) where teacher_id is not null;
create index if not exists conversations_institute on public.conversations (institute_id) where institute_id is not null;

------------------------------------------------------------------------------------------------------------
-- 2. Header counts (PERF-02): the function is unchanged; the partial index messages_unread above lets it read
-- only unread messages of the caller's conversations (measured: a rewrite with IN/UNION was slower).
------------------------------------------------------------------------------------------------------------

------------------------------------------------------------------------------------------------------------
-- 3. owner_bookings (PERF-04 / SCALE-02): the caller's offers are found through indexes instead of checking
-- every booking on the platform; optional p_from limits history. Same columns and same rows as before.
------------------------------------------------------------------------------------------------------------
drop function if exists public.owner_bookings(uuid);
create function public.owner_bookings(p_offering uuid default null, p_from timestamptz default null)
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

------------------------------------------------------------------------------------------------------------
-- 4. seats_overview (PERF-03): optional list of offers, so a page asks only for what it shows.
------------------------------------------------------------------------------------------------------------
drop function if exists public.seats_overview();
create function public.seats_overview(p_offerings uuid[] default null)
returns table (offering_id uuid, session_id uuid, taken int)
language sql stable security definer set search_path = public as $$
  select b.offering_id, b.session_id, count(*)::int
  from bookings b join offerings o on o.id = b.offering_id
  where o.type in ('group','course') and b.status in ('pending','confirmed')
    and (p_offerings is null or b.offering_id = any(p_offerings))
  group by b.offering_id, b.session_id
$$;

------------------------------------------------------------------------------------------------------------
-- 5. Admin-editable limits (decision 1 of phase 3: the 2-hour notice is set from the admin page).
------------------------------------------------------------------------------------------------------------
create or replace function public.admin_set_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := trim(coalesce(p_value, '')); v_n int;
        -- numeric settings: key -> allowed range
        v_ranges jsonb := '{"min_lead_minutes":[0,1440],"max_open_bookings_per_offer":[1,50],"sms_daily_cap_per_user":[0,50],
                            "sms_daily_cap":[0,5000],"otp_per_hour":[1,20],"otp_per_day":[1,100],"staff_invites_per_day":[1,100]}';
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_key in ('platform_bit','support_whatsapp') then
    if v <> '' then
      v := clean_phone(v);
      if v is null then raise exception 'رقم الجوال غير صحيح'; end if;
    end if;
  elsif p_key = 'subscriptions_required' then
    if v not in ('true','false') then raise exception 'قيمة غير صالحة'; end if;
  elsif v_ranges ? p_key then
    if v !~ '^\d{1,5}$' then raise exception 'اكتب رقماً صحيحاً'; end if;
    v_n := v::int;
    if v_n < (v_ranges->p_key->>0)::int or v_n > (v_ranges->p_key->>1)::int then
      raise exception 'القيمة يجب أن تكون بين % و%', v_ranges->p_key->>0, v_ranges->p_key->>1;
    end if;
  else
    raise exception 'إعداد غير معروف';
  end if;
  insert into app_settings (key, value, updated_at) values (p_key, v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

------------------------------------------------------------------------------------------------------------
-- Least privilege: re-created functions get their grants back (the allow-list of phase 1).
------------------------------------------------------------------------------------------------------------
revoke execute on function public.owner_bookings(uuid, timestamptz), public.seats_overview(uuid[]),
  public.admin_set_setting(text, text) from public, anon, authenticated;
grant execute on function public.seats_overview(uuid[]) to anon, authenticated;
grant execute on function public.owner_bookings(uuid, timestamptz), public.admin_set_setting(text, text) to authenticated;
