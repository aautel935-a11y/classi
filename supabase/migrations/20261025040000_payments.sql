-- Classi: paying the teacher directly, in cash or by Bit. No payment gateway.
--  · teachers and institutes add their Bit number (shown only to people who booked with them)
--  · every lesson and package has a payment status:
--      unpaid → (student says "I transferred") reported → (teacher confirms) paid
--      free (trial lesson at 0 ₪) · package (covered by a lesson package)
--  · cash: the teacher marks "received" after the lesson.

-- Bit numbers live apart from the public teacher/institute rows, readable only by their owner
-- (and handed to bookers through my_pay_numbers).
create table if not exists public.pay_numbers (
  id           uuid primary key default gen_random_uuid(),
  teacher_id   uuid unique references public.teachers(id) on delete cascade,
  institute_id uuid unique references public.institutes(id) on delete cascade,
  bit_phone    text,
  updated_at   timestamptz not null default now(),
  check ((teacher_id is null) <> (institute_id is null))
);
alter table public.pay_numbers enable row level security;
create policy "owner reads own pay number" on public.pay_numbers for select
  using (exists (select 1 from teachers t where t.id = teacher_id and t.user_id = auth.uid())
      or exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()));
grant select on public.pay_numbers to authenticated;

alter table public.bookings add column if not exists pay_status text not null default 'unpaid'
  check (pay_status in ('unpaid','reported','paid','free','package'));
alter table public.bookings add column if not exists reported_at timestamptz;
alter table public.bookings add column if not exists paid_at timestamptz;

alter table public.lesson_packages add column if not exists pay_status text not null default 'unpaid'
  check (pay_status in ('unpaid','reported','paid'));
alter table public.lesson_packages add column if not exists reported_at timestamptz;
alter table public.lesson_packages add column if not exists paid_at timestamptz;

-- Status follows the price and the package automatically, until money has moved.
create or replace function public.bookings_pay_status() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.pay_status in ('unpaid','free','package') then
    new.pay_status := case when new.package_id is not null then 'package'
                           when coalesce(new.price, 0) = 0 then 'free'
                           when tg_op = 'UPDATE' and old.pay_status in ('reported','paid') then old.pay_status
                           else 'unpaid' end;
  end if;
  return new;
end $$;
-- named to run after bookings_package and bookings_price (triggers fire in name order)
drop trigger if exists bookings_zz_pay_status on public.bookings;
create trigger bookings_zz_pay_status before insert or update of price, package_id on public.bookings
  for each row execute function public.bookings_pay_status();
update public.bookings set pay_status = case when package_id is not null then 'package' when coalesce(price, 0) = 0 then 'free' else 'unpaid' end
 where pay_status = 'unpaid';

-- ================= Bit number =================
create or replace function public.set_bit_phone(p_phone text, p_institute boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare v text := clean_phone(p_phone);
begin
  if nullif(trim(coalesce(p_phone, '')), '') is not null and v is null then raise exception 'رقم Bit غير صحيح. اكتب رقم جوال مثل 0501234567.'; end if;
  if p_institute then
    insert into pay_numbers (institute_id, bit_phone)
    select id, v from institutes where owner_id = auth.uid() limit 1
    on conflict (institute_id) do update set bit_phone = excluded.bit_phone, updated_at = now();
  else
    insert into pay_numbers (teacher_id, bit_phone)
    select id, v from teachers where user_id = auth.uid() limit 1
    on conflict (teacher_id) do update set bit_phone = excluded.bit_phone, updated_at = now();
  end if;
  if not found then raise exception 'لم يُعثر على ملفك'; end if;
  return v;
end $$;

-- Bit numbers of the teachers/institutes the current user booked with or bought a package from.
create or replace function public.my_pay_numbers()
returns table (offering_id uuid, owner_name text, bit_phone text)
language sql stable security definer set search_path = public as $$
  select o.id, coalesce(t.name, i.name), coalesce(pt.bit_phone, pi.bit_phone)
    from offerings o left join teachers t on t.id = o.teacher_id left join institutes i on i.id = o.institute_id
    left join pay_numbers pt on pt.teacher_id = o.teacher_id left join pay_numbers pi on pi.institute_id = o.institute_id
   where o.id in (select b.offering_id from bookings b where b.booked_by = auth.uid()
                  union select p.offering_id from lesson_packages p where p.user_id = auth.uid())
$$;

-- ================= student: "I transferred" =================
create or replace function public.report_payment(p_booking uuid default null, p_package uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_off uuid; v_amount int; v_who text; v_title text; v_owner uuid; v_when text;
begin
  if p_booking is not null then
    update bookings set pay_status = 'reported', reported_at = now()
     where id = p_booking and booked_by = auth.uid() and pay_status = 'unpaid' and status in ('pending','confirmed')
     returning offering_id, price, fmt_time(starts_at) into v_off, v_amount, v_when;
  elsif p_package is not null then
    update lesson_packages set pay_status = 'reported', reported_at = now()
     where id = p_package and user_id = auth.uid() and pay_status = 'unpaid' and status <> 'cancelled'
     returning offering_id, price into v_off, v_amount;
  end if;
  if v_off is null then raise exception 'لا يوجد مبلغ بانتظار الدفع هنا'; end if;
  select title into v_title from offerings where id = v_off;
  select full_name into v_who from profiles where id = auth.uid();
  v_owner := offering_owner_user(v_off);
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (v_owner, 'payment_reported',
      format('أبلغ %s عن تحويل %s ₪ عبر Bit: %s%s. تأكد من وصول المبلغ.', coalesce(v_who, 'طالب'), v_amount, v_title,
             case when p_package is not null then ' (رزمة حصص)' else coalesce('، حصة ' || v_when, '') end),
      '/teach#payments');
  end if;
end $$;

-- ================= teacher: confirm received (or not) =================
create or replace function public.confirm_payment(p_booking uuid default null, p_package uuid default null, p_received boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare v_off uuid; v_user uuid; v_amount int; v_title text; v_was text;
begin
  if p_booking is not null then
    select offering_id, booked_by, price, pay_status into v_off, v_user, v_amount, v_was from bookings where id = p_booking;
  else
    select offering_id, user_id, price, pay_status into v_off, v_user, v_amount, v_was from lesson_packages where id = p_package;
  end if;
  if v_off is null or not is_offering_owner(v_off) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  if v_was not in ('unpaid','reported','paid') then raise exception 'هذه الحصة لا تحتاج دفعاً (مجانية أو ضمن رزمة)'; end if;
  if p_booking is not null then
    update bookings set pay_status = case when p_received then 'paid' else 'unpaid' end,
                        paid_at = case when p_received then now() end,
                        reported_at = case when p_received then reported_at end
     where id = p_booking;
  else
    update lesson_packages set pay_status = case when p_received then 'paid' else 'unpaid' end,
                               paid_at = case when p_received then now() end,
                               reported_at = case when p_received then reported_at end
     where id = p_package;
  end if;
  select title into v_title from offerings where id = v_off;
  -- the student hears back only about a Bit transfer they reported
  if v_was = 'reported' then
    insert into notifications (user_id, kind, body, link) values (v_user, 'payment_answer',
      case when p_received then format('أكّد المعلم استلام %s ₪: %s. شكراً!', v_amount, v_title)
           else format('لم يصل تحويل %s ₪ للمعلم بعد: %s. تأكد من رقم Bit وحاول مرة أخرى.', v_amount, v_title) end,
      '/schedule');
  end if;
end $$;

-- ================= teacher's money overview =================
-- Lessons and packages waiting for payment: transfers reported, and unpaid lessons that already took place.
create or replace function public.owner_payments()
returns table (kind text, id uuid, offering_id uuid, title text, who text, amount int, pay_method text, pay_status text, lesson_at timestamptz, reported_at timestamptz)
language sql stable security definer set search_path = public as $$
  select 'booking', b.id, o.id, o.title, coalesce(c.name, p.full_name, 'طالب'), b.price, b.pay_method, b.pay_status,
         coalesce(b.starts_at, s.starts_at), b.reported_at
    from bookings b join offerings o on o.id = b.offering_id
    left join sessions s on s.id = b.session_id
    left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
   where is_offering_owner(o.id) and b.status = 'confirmed'
     and (b.pay_status = 'reported' or (b.pay_status = 'unpaid' and coalesce(b.starts_at, s.starts_at, b.created_at) <= now() + interval '1 day'))
  union all
  select 'package', k.id, o.id, o.title || ' · رزمة ' || k.size || ' حصص', coalesce(c.name, p.full_name, 'طالب'), k.price, k.pay_method, k.pay_status,
         k.created_at, k.reported_at
    from lesson_packages k join offerings o on o.id = k.offering_id
    left join children c on c.id = k.child_id left join profiles p on p.id = k.user_id
   where is_offering_owner(o.id) and k.status <> 'cancelled' and k.pay_status in ('unpaid','reported')
  order by 8 desc, 9 desc
$$;

-- Money received this month and still open, for the dashboard.
create or replace function public.owner_money_summary()
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

-- The roster helper returns price and payment status too.
drop function if exists public.owner_bookings(uuid);
create or replace function public.owner_bookings(p_offering uuid default null)
returns table (
  booking_id uuid, offering_id uuid, offering_title text, offering_type public.offering_type,
  student_name text, starts_at timestamptz, session_id uuid, status public.booking_status,
  pay_method text, created_at timestamptz, mode public.place_kind, weekly boolean, series_id uuid, series_count int,
  price int, pay_status text)
language sql stable security definer set search_path = public as $$
  select b.id, o.id, o.title, o.type,
         coalesce(c.name, p.full_name, 'طالب'), coalesce(b.starts_at, s.starts_at), b.session_id,
         b.status, b.pay_method, b.created_at, b.mode, b.weekly, b.series_id,
         case when b.series_id is null then null
              else (select count(*)::int from bookings x where x.series_id = b.series_id and x.status in ('pending','confirmed')) end,
         b.price, b.pay_status
  from bookings b
  join offerings o on o.id = b.offering_id
  left join children c on c.id = b.child_id
  left join profiles p on p.id = b.booked_by
  left join sessions s on s.id = b.session_id
  where is_offering_staff(o.id) and (p_offering is null or o.id = p_offering)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;

drop function if exists public.owner_packages(uuid);
create or replace function public.owner_packages(p_offering uuid)
returns table (id uuid, student_name text, size int, remaining int, price int, pay_method text, status text, created_at timestamptz, pay_status text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(c.name, pr.full_name, 'طالب'), p.size, p.remaining, p.price, p.pay_method, p.status, p.created_at, p.pay_status
    from lesson_packages p left join children c on c.id = p.child_id left join profiles pr on pr.id = p.user_id
   where p.offering_id = p_offering and is_offering_staff(p_offering)
   order by p.status = 'active' desc, p.created_at desc
$$;

-- The teacher's calendar shows payment too.
drop function if exists public.my_teacher_calendar(timestamptz, timestamptz);
create or replace function public.my_teacher_calendar(p_from timestamptz, p_to timestamptz)
returns table (kind text, id uuid, starts_at timestamptz, minutes int, title text, who text, status text,
               series_id uuid, mode public.place_kind, note text, offering_id uuid, changed boolean, pay_status text, pay_method text, price int)
language sql stable security definer set search_path = public as $$
  with me as (select my_teacher_id() t)
  select 'booking', b.id, b.starts_at, b.minutes, o.title, coalesce(c.name, p.full_name, 'طالب'), b.status::text,
         b.series_id, b.mode, null, o.id, b.changed_at is not null, b.pay_status, b.pay_method, b.price
    from bookings b join offerings o on o.id = b.offering_id join me on o.teacher_id = me.t
    left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
   where b.status in ('pending','confirmed') and b.starts_at between p_from and p_to
  union all
  select 'session', s.id, s.starts_at, s.minutes, o.title,
         (select count(*)::text from bookings x where x.status = 'confirmed' and (x.session_id = s.id or (o.type = 'course' and x.offering_id = o.id and x.session_id is null))),
         case when o.institute_id is not null then 'institute' else 'group' end, null, null, null, o.id, s.changed, null, null, null
    from sessions s join offerings o on o.id = s.offering_id join me on (o.teacher_id = me.t or o.course_teacher_id = me.t)
   where not s.cancelled and s.starts_at between p_from and p_to
  union all
  select 'block', k.id, k.starts_at, k.minutes, null, null, null, null, null, k.note, null, false, null, null, null
    from teacher_blocks k join me on k.teacher_id = me.t
   where k.starts_at between p_from and p_to
  order by 3
$$;

-- Payment answers reach the phone too.
create or replace function public.notifications_mark_push() returns trigger
language plpgsql as $$
begin
  new.want_push := new.kind in ('reminder','reminder_soon','booking_answer','booking_request','booking_new','booking_cancelled',
                                'schedule_changed','waitlist_open','waitlist_answer','waitlist_join','verified','message',
                                'lesson_report','report_due','payment_reported','payment_answer');
  return new;
end $$;

revoke execute on function public.set_bit_phone, public.my_pay_numbers, public.report_payment, public.confirm_payment,
  public.owner_payments, public.owner_money_summary, public.owner_bookings, public.owner_packages, public.my_teacher_calendar from anon, public;
grant execute on function public.set_bit_phone, public.my_pay_numbers, public.report_payment, public.confirm_payment,
  public.owner_payments, public.owner_money_summary, public.owner_bookings, public.owner_packages, public.my_teacher_calendar to authenticated;
