-- Classi: fixes from the role-by-role test.

-- 1. Offers of a teacher or institute that is not verified yet stay hidden,
--    and cannot be booked.
create or replace function public.offering_owner_verified(p_offering uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select t.verify = 'verified' from offerings o join teachers t on t.id = o.teacher_id where o.id = p_offering),
    (select i.verify = 'verified' from offerings o join institutes i on i.id = o.institute_id where o.id = p_offering),
    false)
$$;

drop policy if exists "read offerings" on public.offerings;
create policy "read offerings" on public.offerings for select
  using ((active and offering_owner_verified(id)) or is_offering_owner(id) or is_admin());

-- 2. The teacher of an institute course works with it too: sees the roster
--    and takes attendance (changing times stays with the institute).
create or replace function public.is_offering_staff(p_offering uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_offering_owner(p_offering) or exists (
    select 1 from offerings o join teachers t on t.id = o.course_teacher_id
    where o.id = p_offering and t.user_id = auth.uid())
$$;
grant execute on function public.is_offering_staff, public.offering_owner_verified to anon, authenticated;

drop policy if exists "see bookings" on public.bookings;
create policy "see bookings" on public.bookings for select
  using (booked_by = auth.uid() or is_offering_staff(offering_id));

drop policy if exists "owner attendance" on public.attendance;
create policy "staff attendance" on public.attendance for all
  using (exists (select 1 from sessions s where s.id = session_id and is_offering_staff(s.offering_id)))
  with check (exists (select 1 from sessions s where s.id = session_id and is_offering_staff(s.offering_id)));

-- 3. Private lessons offered both at home and online: the student picks one.
alter table public.bookings add column if not exists mode public.place_kind;

-- 4. Zoom / Meet link for online lessons, and the content link for recorded
--    packages. Only the owner, the course teacher and confirmed students see it.
create table if not exists public.offering_links (
  offering_id uuid primary key references public.offerings(id) on delete cascade,
  url         text not null check (url ~* '^https?://'),
  note        text,
  updated_at  timestamptz not null default now()
);
alter table public.offering_links enable row level security;
create policy "staff manage links" on public.offering_links for all
  using (is_offering_staff(offering_id)) with check (is_offering_staff(offering_id));
create policy "confirmed students read links" on public.offering_links for select
  using (exists (select 1 from bookings b where b.offering_id = offering_links.offering_id
                 and b.booked_by = auth.uid() and b.status = 'confirmed'));
grant select, insert, update, delete on public.offering_links to authenticated;

-- 5. The town chosen at sign-up is kept even when the email has to be confirmed first.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_role app_role;
begin
  v_role := case when new.raw_user_meta_data->>'role' in ('guardian','student','teacher','institute')
                 then (new.raw_user_meta_data->>'role')::app_role else 'guardian' end;
  insert into profiles (id, full_name, phone, town, roles, active_role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''), new.phone,
          nullif(new.raw_user_meta_data->>'town', ''), array[v_role], v_role)
  on conflict (id) do nothing;
  return new;
end $$;

-- 6. Booking: owner must be verified; mode is checked against the offer; a
--    teacher cannot book their own offer.
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
  select * into o from offerings where id = p_offering and active;
  if not found or not offering_owner_verified(o.id) then raise exception 'هذا العرض غير متاح'; end if;
  if is_offering_owner(o.id) then raise exception 'لا يمكنك حجز عرضك أنت'; end if;

  if p_child is not null and not exists (select 1 from children where id = p_child and guardian_id = auth.uid()) then
    raise exception 'هذا الطالب غير مرتبط بحسابك';
  end if;

  v_mode := coalesce(p_mode, o.places[1]);
  if not v_mode = any(o.places) then raise exception 'طريقة الحضور غير متاحة لهذا العرض'; end if;

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

  insert into bookings (offering_id, session_id, booked_by, child_id, starts_at, minutes, status, pay_method, weekly, mode)
  values (o.id, p_session, auth.uid(), p_child, p_starts_at, o.minutes, v_status, p_pay, coalesce(p_weekly, false), v_mode)
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
        else format('حجز جديد من %s: %s', v_who, o.title) end,
      case when o.institute_id is not null then '/manage' else '/teach' end);
  end if;
  return v_id;
end $$;
drop function if exists public.create_booking(uuid, uuid, timestamptz, uuid, text, boolean);
revoke execute on function public.create_booking from anon, public;
grant execute on function public.create_booking to authenticated;

-- 7. The roster helper also serves the course teacher, and returns the mode.
drop function if exists public.owner_bookings(uuid);
create or replace function public.owner_bookings(p_offering uuid default null)
returns table (
  booking_id uuid, offering_id uuid, offering_title text, offering_type public.offering_type,
  student_name text, starts_at timestamptz, session_id uuid, status public.booking_status,
  pay_method text, created_at timestamptz, mode public.place_kind, weekly boolean)
language sql stable security definer set search_path = public as $$
  select b.id, o.id, o.title, o.type,
         coalesce(c.name, p.full_name, 'طالب'), coalesce(b.starts_at, s.starts_at), b.session_id,
         b.status, b.pay_method, b.created_at, b.mode, b.weekly
  from bookings b
  join offerings o on o.id = b.offering_id
  left join children c on c.id = b.child_id
  left join profiles p on p.id = b.booked_by
  left join sessions s on s.id = b.session_id
  where is_offering_staff(o.id) and (p_offering is null or o.id = p_offering)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;
revoke execute on function public.owner_bookings from anon, public;
grant execute on function public.owner_bookings to authenticated;

-- 8. A student keeps seeing what they booked even if the offer is later hidden.
drop policy if exists "read offerings" on public.offerings;
create policy "read offerings" on public.offerings for select
  using ((active and offering_owner_verified(id)) or is_offering_owner(id) or is_admin()
         or exists (select 1 from bookings b where b.offering_id = offerings.id and b.booked_by = auth.uid()));

-- 9. When the Zoom or content link is added or changed, confirmed students are told.
create or replace function public.notify_link_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_title text; v_type offering_type;
begin
  if tg_op = 'UPDATE' and new.url = old.url then return new; end if;
  select title, type into v_title, v_type from offerings where id = new.offering_id;
  insert into notifications (user_id, kind, body, link)
  select distinct b.booked_by, 'link',
         case when v_type = 'recorded' then format('رابط المحتوى جاهز: %s', v_title)
              else format('رابط اللقاء أونلاين جاهز: %s', v_title) end,
         '/schedule'
  from bookings b where b.offering_id = new.offering_id and b.status = 'confirmed';
  return new;
end $$;
drop trigger if exists offering_links_notify on public.offering_links;
create trigger offering_links_notify after insert or update on public.offering_links
  for each row execute function public.notify_link_change();
