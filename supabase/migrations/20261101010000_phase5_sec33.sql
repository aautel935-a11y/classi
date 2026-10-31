-- Classi phase 5: SEC-33. Two simultaneous requests could give a family two trial lessons with the same teacher,
-- or two active packages for the same offer (reproduced in supabase/tests/concurrency_test.sh before this file).
-- Each function now takes a transaction-scoped advisory lock for that family and teacher / offer before checking.
-- Same bodies otherwise (from 20261025020000_trial_packages.sql). Safe on a live database: function bodies only.

create or replace function public.create_trial_booking(
  p_offering uuid, p_child uuid default null, p_starts_at timestamptz default null, p_pay text default 'bit', p_mode public.place_kind default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_id uuid; v_owner uuid;
begin
  select * into o from offerings where id = p_offering;
  if not found or o.type <> 'private' or o.trial_price is null then raise exception 'لا توجد حصة تجريبية لهذا العرض'; end if;
  -- SEC-33: one family's simultaneous trial requests with the same teacher or institute run one after the other,
  -- so the second sees the first and is refused (held until the end of the transaction).
  perform pg_advisory_xact_lock(hashtextextended(format('trial:%s:%s:%s', auth.uid(), p_child, coalesce(o.teacher_id, o.institute_id)), 0));
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
  -- SEC-33: two simultaneous purchases of the same package run one after the other; the second sees the first.
  perform pg_advisory_xact_lock(hashtextextended(format('package:%s:%s:%s', auth.uid(), p_child, o.id), 0));
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

-- Least privilege: create or replace keeps the existing grants (authenticated only); restated for fresh builds.
revoke execute on function public.create_trial_booking(uuid, uuid, timestamptz, text, public.place_kind), public.buy_package(uuid, uuid, text) from public, anon;
grant execute on function public.create_trial_booking(uuid, uuid, timestamptz, text, public.place_kind), public.buy_package(uuid, uuid, text) to authenticated;
