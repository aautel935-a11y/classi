-- Classi: trial lessons, teacher intro videos, and lesson packages. All optional, switched on by the teacher.
--  · trial: a first private lesson free or at a lower price, once per student per teacher
--  · intro video: a short link on the teacher's profile (YouTube, Instagram, TikTok, Drive…)
--  · packages: N lessons for a total price; each booking of that offer uses one lesson automatically,
--    and a cancelled lesson goes back into the package.

alter table public.teachers  add column if not exists intro_video_url text check (intro_video_url is null or (intro_video_url ~ '^https://' and length(intro_video_url) <= 300));
alter table public.offerings add column if not exists trial_price int check (trial_price is null or trial_price >= 0);
alter table public.offerings add column if not exists package_enabled boolean not null default false;
alter table public.offerings add column if not exists package_size int check (package_size is null or package_size between 2 and 50);
alter table public.offerings add column if not exists package_price int check (package_price is null or package_price >= 0);
alter table public.bookings  add column if not exists is_trial boolean not null default false;

create table if not exists public.lesson_packages (
  id          uuid primary key default gen_random_uuid(),
  offering_id uuid not null references public.offerings(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  child_id    uuid references public.children(id) on delete set null,
  size        int not null,
  remaining   int not null check (remaining >= 0),
  price       int not null,
  pay_method  text not null default 'bit',
  status      text not null default 'active' check (status in ('active','used','cancelled')),
  created_at  timestamptz not null default now()
);
create index if not exists lesson_packages_owner on public.lesson_packages (offering_id, user_id);
alter table public.bookings add column if not exists package_id uuid references public.lesson_packages(id) on delete set null;

alter table public.lesson_packages enable row level security;
create policy "see own or staff packages" on public.lesson_packages for select
  using (user_id = auth.uid() or is_offering_staff(offering_id) or is_admin());
grant select on public.lesson_packages to authenticated;

-- ================= trial lesson =================
-- Has this student (or this child) ever had a lesson booked with this offer's teacher or institute?
create or replace function public.trial_available(p_offering uuid, p_child uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select o.type = 'private' and o.trial_price is not null and auth.uid() is not null
     and not exists (
       select 1 from bookings b join offerings x on x.id = b.offering_id
        where b.booked_by = auth.uid() and b.child_id is not distinct from p_child
          and b.status in ('pending','confirmed')
          and (x.teacher_id = o.teacher_id or x.institute_id = o.institute_id))
     and not exists (
       select 1 from bookings b join offerings x on x.id = b.offering_id
        where b.booked_by = auth.uid() and b.child_id is not distinct from p_child and b.is_trial
          and (x.teacher_id = o.teacher_id or x.institute_id = o.institute_id))
  from offerings o where o.id = p_offering
$$;

create or replace function public.create_trial_booking(
  p_offering uuid, p_child uuid default null, p_starts_at timestamptz default null, p_pay text default 'bit', p_mode public.place_kind default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_id uuid; v_owner uuid;
begin
  select * into o from offerings where id = p_offering;
  if not found or o.type <> 'private' or o.trial_price is null then raise exception 'لا توجد حصة تجريبية لهذا العرض'; end if;
  if not trial_available(p_offering, p_child) then raise exception 'الحصة التجريبية متاحة مرة واحدة لكل طالب مع هذا المعلم'; end if;
  v_id := create_booking(p_offering, p_child, p_starts_at, null, p_pay, false, p_mode);
  update bookings set is_trial = true, price = o.trial_price, package_id = null where id = v_id;
  -- give back a package lesson if the trigger used one
  update lesson_packages set remaining = remaining + 1, status = 'active'
   where id = (select package_id from bookings where id = v_id);
  v_owner := offering_owner_user(o.id);
  update notifications set body = 'حصة تجريبية' || case when o.trial_price = 0 then ' مجانية' else format(' (%s ₪)', o.trial_price) end || ' · ' || body
   where user_id in (v_owner, auth.uid()) and created_at = now() and kind in ('booking_request','booking_new','booking_answer');
  return v_id;
end $$;

-- ================= packages =================
create or replace function public.buy_package(p_offering uuid, p_child uuid default null, p_pay text default 'bit') returns uuid
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_id uuid; v_owner uuid; v_who text;
begin
  if auth.uid() is null then raise exception 'سجّل الدخول أولاً'; end if;
  if not is_active_user() then raise exception 'حسابك موقوف حالياً'; end if;
  select * into o from offerings where id = p_offering and active and not moderation_hidden;
  if not found or not offering_owner_verified(o.id) then raise exception 'هذا العرض غير متاح'; end if;
  if not o.package_enabled or o.package_size is null or o.package_price is null or o.type not in ('private','group') then
    raise exception 'هذا العرض لا يقدّم رزم حصص';
  end if;
  if is_offering_owner(o.id) then raise exception 'هذا عرضك أنت'; end if;
  if p_child is not null and not exists (select 1 from children where id = p_child and guardian_id = auth.uid()) then
    raise exception 'هذا الطالب غير مرتبط بحسابك';
  end if;
  if exists (select 1 from lesson_packages where offering_id = o.id and user_id = auth.uid() and child_id is not distinct from p_child and status = 'active') then
    raise exception 'لديك رزمة فعّالة لهذا العرض. تُشترى الرزمة التالية بعد انتهائها.';
  end if;
  insert into lesson_packages (offering_id, user_id, child_id, size, remaining, price, pay_method)
  values (o.id, auth.uid(), p_child, o.package_size, o.package_size, o.package_price, coalesce(nullif(p_pay, ''), 'bit'))
  returning id into v_id;

  -- Lessons already booked ahead (e.g. a weekly slot) start using the package right away.
  perform package_apply_existing(v_id);

  v_owner := offering_owner_user(o.id);
  select coalesce((select name from children where id = p_child), (select full_name from profiles where id = auth.uid())) into v_who;
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (v_owner, 'booking_new',
      format('اشترى %s رزمة %s حصص في %s بـ %s ₪ (%s). تأكد من استلام الدفع.', v_who, o.package_size, o.title, o.package_price,
             case p_pay when 'cash' then 'نقداً' else 'Bit' end), '/manage/course/' || o.id);
  end if;
  insert into notifications (user_id, kind, body, link) values (auth.uid(), 'booking_answer',
    format('رزمة %s حصص في %s جاهزة. كل حجز قادم يُخصم منها تلقائياً.', o.package_size, o.title), '/offer/' || o.id);
  return v_id;
end $$;

-- Moves already-booked future lessons onto a new package (oldest first), as many as it covers.
create or replace function public.package_apply_existing(p_package uuid) returns int
language plpgsql security definer set search_path = public as $$
declare p lesson_packages%rowtype; b record; v_n int := 0;
begin
  select * into p from lesson_packages where id = p_package for update;
  for b in select bk.id from bookings bk left join sessions s on s.id = bk.session_id
            where bk.offering_id = p.offering_id and bk.booked_by = p.user_id and bk.child_id is not distinct from p.child_id
              and bk.status in ('pending','confirmed') and bk.package_id is null and not bk.is_trial
              and coalesce(bk.starts_at, s.starts_at) > now()
            order by coalesce(bk.starts_at, s.starts_at) limit p.remaining loop
    update bookings set package_id = p.id, price = round(p.price::numeric / p.size) where id = b.id;
    v_n := v_n + 1;
  end loop;
  update lesson_packages set remaining = remaining - v_n, status = case when remaining - v_n = 0 then 'used' else status end where id = p.id;
  return v_n;
end $$;

-- New bookings use a lesson from an active package automatically.
create or replace function public.bookings_use_package() returns trigger
language plpgsql security definer set search_path = public as $$
declare p lesson_packages%rowtype;
begin
  if new.package_id is not null or new.is_trial or new.status not in ('pending','confirmed') then return new; end if;
  select * into p from lesson_packages
   where offering_id = new.offering_id and user_id = new.booked_by and child_id is not distinct from new.child_id
     and status = 'active' and remaining > 0
   order by created_at limit 1 for update;
  if not found then return new; end if;
  new.package_id := p.id;
  new.price := round(p.price::numeric / p.size);
  update lesson_packages set remaining = remaining - 1, status = case when remaining - 1 = 0 then 'used' else status end where id = p.id;
  if p.remaining - 1 = 0 then
    insert into notifications (user_id, kind, body, link)
    select new.booked_by, 'booking_answer', format('استُعملت آخر حصة في رزمتك: %s. يمكنك شراء رزمة جديدة من صفحة العرض.', o.title), '/offer/' || o.id
      from offerings o where o.id = new.offering_id;
  end if;
  return new;
end $$;
drop trigger if exists bookings_package on public.bookings;
create trigger bookings_package before insert on public.bookings
  for each row execute function public.bookings_use_package();

-- A cancelled or declined lesson goes back into its package.
create or replace function public.bookings_return_package() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.package_id is not null and old.status in ('pending','confirmed') and new.status not in ('pending','confirmed') then
    update lesson_packages set remaining = remaining + 1, status = case when status = 'used' then 'active' else status end
     where id = old.package_id and status <> 'cancelled';
  end if;
  return new;
end $$;
drop trigger if exists bookings_package_return on public.bookings;
create trigger bookings_package_return after update of status on public.bookings
  for each row execute function public.bookings_return_package();

-- The teacher/institute cancels a package (e.g. refund arranged with the parent).
create or replace function public.cancel_package(p_package uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p lesson_packages%rowtype; v_title text;
begin
  select * into p from lesson_packages where id = p_package;
  if not found or not is_offering_owner(p.offering_id) then raise exception 'لا تملك صلاحية على هذه الرزمة'; end if;
  if p.status = 'cancelled' then raise exception 'الرزمة ملغاة سابقاً'; end if;
  update lesson_packages set status = 'cancelled' where id = p.id;
  -- future lessons stay booked, at the normal price
  update bookings b set package_id = null, price = o.price from offerings o
   where b.package_id = p.id and o.id = b.offering_id and b.status in ('pending','confirmed') and coalesce(b.starts_at, now() + interval '1 day') > now();
  select title into v_title from offerings where id = p.offering_id;
  insert into notifications (user_id, kind, body, link)
  values (p.user_id, 'booking_cancelled', format('أُلغيت رزمة الحصص في %s (بقي فيها %s حصص). تواصل مع المعلم بخصوص المبلغ.', v_title, p.remaining), '/schedule');
end $$;

-- Packages for the teacher's offer page.
create or replace function public.owner_packages(p_offering uuid)
returns table (id uuid, student_name text, size int, remaining int, price int, pay_method text, status text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(c.name, pr.full_name, 'طالب'), p.size, p.remaining, p.price, p.pay_method, p.status, p.created_at
    from lesson_packages p left join children c on c.id = p.child_id left join profiles pr on pr.id = p.user_id
   where p.offering_id = p_offering and is_offering_staff(p_offering)
   order by p.status = 'active' desc, p.created_at desc
$$;

revoke execute on function public.create_trial_booking, public.buy_package, public.cancel_package, public.owner_packages,
  public.package_apply_existing, public.trial_available from anon, public;
grant execute on function public.create_trial_booking, public.buy_package, public.cancel_package, public.owner_packages,
  public.trial_available to authenticated;
