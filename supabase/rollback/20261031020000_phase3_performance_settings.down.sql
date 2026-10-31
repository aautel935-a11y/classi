-- Rollback of supabase/migrations/20261031020000_phase3_performance_settings.sql
-- Order: roll the APP back first (the phase 3 app calls seats_overview(p_offerings) and the new admin settings).
-- The phase 2/1 protections are not touched. replace_availability keeps the phase 3 body on purpose: the phase 2
-- body fails on Supabase (pg_safeupdate), and the fixed one behaves the same otherwise.
begin;

-- 1. Indexes (harmless to keep; dropped only for a full return to phase 2)
drop index if exists public.bookings_live_starts, public.bookings_session, public.sessions_offering_starts,
  public.availability_teacher_day, public.offerings_course_teacher, public.children_guardian, public.institutes_owner,
  public.reviews_teacher_recent, public.reviews_institute_recent, public.messages_unread, public.conversations_teacher,
  public.conversations_institute;

-- 2. owner_bookings and seats_overview: phase 2 signatures and bodies
drop function if exists public.owner_bookings(uuid, timestamptz);
create function public.owner_bookings(p_offering uuid default null)
returns table (booking_id uuid, offering_id uuid, offering_title text, offering_type offering_type, student_name text, starts_at timestamptz,
               session_id uuid, status booking_status, pay_method text, created_at timestamptz, mode place_kind, weekly boolean, series_id uuid,
               series_count int, price int, pay_status text, installments_total int, installments_paid int, offline boolean, offline_phone text,
               can_link boolean)
language sql stable security definer set search_path = public as $$
  select b.id, o.id, o.title, o.type,
         coalesce(c.name, b.offline_name, p.full_name, 'طالب'), coalesce(b.starts_at, s.starts_at), b.session_id,
         b.status, b.pay_method, b.created_at, b.mode, b.weekly, b.series_id,
         case when b.series_id is null then null
              else (select count(*)::int from bookings x where x.series_id = b.series_id and x.status in ('pending','confirmed')) end,
         b.price, b.pay_status, b.installments_total, b.installments_paid, b.booked_by is null, b.offline_phone,
         b.booked_by is null and b.offline_phone is not null and is_offering_owner(o.id)
  from bookings b
  join offerings o on o.id = b.offering_id
  left join children c on c.id = b.child_id
  left join profiles p on p.id = b.booked_by
  left join sessions s on s.id = b.session_id
  where is_offering_staff(o.id) and (p_offering is null or o.id = p_offering)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;
drop function if exists public.seats_overview(uuid[]);
create function public.seats_overview()
returns table (offering_id uuid, session_id uuid, taken int)
language sql stable security definer set search_path = public as $$
  select b.offering_id, b.session_id, count(*)::int
  from bookings b join offerings o on o.id = b.offering_id
  where o.type in ('group','course') and b.status in ('pending','confirmed')
  group by b.offering_id, b.session_id
$$;

-- 3. admin_set_setting: only the three original keys (the numeric limits stay as they are in app_settings)
create or replace function public.admin_set_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := trim(coalesce(p_value, ''));
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_key not in ('subscriptions_required','platform_bit','support_whatsapp') then raise exception 'إعداد غير معروف'; end if;
  if p_key in ('platform_bit','support_whatsapp') and v <> '' then
    v := clean_phone(v);
    if v is null then raise exception 'رقم الجوال غير صحيح'; end if;
  end if;
  if p_key = 'subscriptions_required' and v not in ('true','false') then raise exception 'قيمة غير صالحة'; end if;
  insert into app_settings (key, value, updated_at) values (p_key, v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

-- 4. Least privilege: the same allow-list as before phase 3
revoke execute on function public.owner_bookings(uuid), public.seats_overview(), public.admin_set_setting(text, text)
  from public, anon, authenticated;
grant execute on function public.seats_overview() to anon, authenticated;
grant execute on function public.owner_bookings(uuid), public.admin_set_setting(text, text) to authenticated;

-- 5. The read policy of offerings stays as phase 3 defines it: the older one makes publishing a new offer fail.

commit;
