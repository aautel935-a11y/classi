-- Classi: admin operations for day-to-day disputes.
--  1. find any booking by phone, name or email
--  2. cancel a booking for either side, settle a payment status
--  3. send a direct note to one user (in-app + push, and SMS when they allowed it)
--  4. platform numbers at a glance
--  5. fix an offer's title directly (no reject-and-wait round trip)
-- Every action is written to moderation_actions (the admin log) and both sides are told.

create or replace function public.admin_find_bookings(p_q text)
returns table (booking_id uuid, offering_id uuid, title text, owner_name text, student text, parent text, parent_phone text,
               starts_at timestamptz, status text, pay_status text, pay_method text, price int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_q text := nullif(trim(p_q), ''); v_phone text := clean_phone(p_q);
begin
  if not is_admin() then raise exception 'للمدير فقط'; end if;
  if v_q is null or char_length(v_q) < 2 then return; end if;
  return query
  select b.id, o.id, o.title, coalesce(t.name, i.name, ''),
         coalesce(c.name, b.offline_name, p.full_name, 'طالب'), p.full_name, coalesce(p.phone, b.offline_phone),
         coalesce(b.starts_at, s.starts_at), b.status::text, b.pay_status, b.pay_method, b.price, b.created_at
    from bookings b
    join offerings o on o.id = b.offering_id
    left join teachers t on t.id = coalesce(o.teacher_id, o.course_teacher_id)
    left join institutes i on i.id = o.institute_id
    left join profiles p on p.id = b.booked_by
    left join children c on c.id = b.child_id
    left join sessions s on s.id = b.session_id
    left join auth.users u on u.id = b.booked_by
   where (v_phone is not null and (p.phone = v_phone or b.offline_phone = v_phone))
      or (v_phone is null and (p.full_name ilike '%' || v_q || '%' or c.name ilike '%' || v_q || '%' or b.offline_name ilike '%' || v_q || '%'
                               or u.email ilike '%' || v_q || '%' or t.name ilike '%' || v_q || '%' or i.name ilike '%' || v_q || '%'))
   order by coalesce(b.starts_at, s.starts_at, b.created_at) desc
   limit 100;
end $$;

create or replace function public.admin_cancel_booking(p_booking uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_title text; v_owner uuid; v_reason text := nullif(trim(p_reason), ''); v_when text;
begin
  if not is_admin() then raise exception 'للمدير فقط'; end if;
  if v_reason is null then raise exception 'اكتب سبب الإلغاء، يصل للطرفين'; end if;
  select * into b from bookings where id = p_booking;
  if not found then raise exception 'الحجز غير موجود'; end if;
  if b.status not in ('pending','confirmed') then raise exception 'الحجز ملغى سابقاً'; end if;
  update bookings set status = 'cancelled' where id = b.id;  -- package lessons return, waitlist is told (existing triggers)
  select title into v_title from offerings where id = b.offering_id;
  v_owner := offering_owner_user(b.offering_id);
  v_when := coalesce(' (' || fmt_time(coalesce(b.starts_at, (select starts_at from sessions where id = b.session_id))) || ')', '');
  insert into notifications (user_id, kind, body, link)
  select x, 'booking_cancelled', format('ألغت إدارة Classi حجز %s%s. السبب: %s', v_title, v_when, v_reason), l
    from (values (b.booked_by, '/schedule'), (v_owner, '/teach')) v(x, l) where x is not null;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), 'booking', b.id, 'cancel_booking', v_reason);
end $$;

create or replace function public.admin_set_payment(p_booking uuid, p_status text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_title text; v_owner uuid; v_reason text := nullif(trim(p_reason), ''); v_label text;
begin
  if not is_admin() then raise exception 'للمدير فقط'; end if;
  if p_status not in ('unpaid','paid','free') then raise exception 'حالة غير معروفة'; end if;
  if v_reason is null then raise exception 'اكتب سبب القرار، يصل للطرفين'; end if;
  select * into b from bookings where id = p_booking;
  if not found then raise exception 'الحجز غير موجود'; end if;
  update bookings set pay_status = p_status,
                      paid_at = case when p_status = 'paid' then now() end,
                      reported_at = case when p_status = 'unpaid' then null else reported_at end,
                      installments_paid = case when p_status = 'paid' then installments_total else installments_paid end
   where id = b.id;
  select title into v_title from offerings where id = b.offering_id;
  v_owner := offering_owner_user(b.offering_id);
  v_label := case p_status when 'paid' then 'مدفوع' when 'free' then 'مجاني' else 'غير مدفوع' end;
  insert into notifications (user_id, kind, body, link)
  select x, 'payment_answer', format('حسمت إدارة Classi حالة الدفع لـ %s: %s. %s', v_title, v_label, v_reason), l
    from (values (b.booked_by, '/schedule'), (v_owner, '/teach#payments')) v(x, l) where x is not null;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), 'booking', b.id, 'pay_' || p_status, v_reason);
end $$;

-- Direct note from the admin: in-app and push always, SMS when the user allowed SMS.
create or replace function public.sms_kinds() returns text[] language sql immutable as $$
  select array['reminder','schedule_changed','booking_cancelled','admin_note']
$$;

create or replace function public.admin_message(p_user uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare v_body text := nullif(trim(p_body), '');
begin
  if not is_admin() then raise exception 'للمدير فقط'; end if;
  if v_body is null or char_length(v_body) > 300 then raise exception 'اكتب رسالة حتى 300 حرف'; end if;
  if not exists (select 1 from profiles where id = p_user) then raise exception 'الحساب غير موجود'; end if;
  insert into notifications (user_id, kind, body, link) values (p_user, 'admin_note', 'من إدارة Classi: ' || v_body, '/notifications');
  insert into moderation_actions (admin_id, target_type, target_id, action, reason) values (auth.uid(), 'user', p_user, 'message', v_body);
end $$;

create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'للمدير فقط'; end if;
  select jsonb_build_object(
    'bookings_7d', (select count(*) from bookings where created_at > now() - interval '7 days' and status in ('pending','confirmed')),
    'bookings_prev7d', (select count(*) from bookings where created_at between now() - interval '14 days' and now() - interval '7 days' and status in ('pending','confirmed')),
    'lessons_7d', (select count(*) from bookings b left join sessions s on s.id = b.session_id
                    where b.status = 'confirmed' and coalesce(b.starts_at, s.starts_at) between now() - interval '7 days' and now()),
    'cancelled_7d', (select count(*) from bookings where status = 'cancelled' and created_at > now() - interval '7 days'),
    'new_users_7d', (select count(*) from profiles where created_at > now() - interval '7 days'),
    'users', (select count(*) from profiles),
    'teachers', (select count(*) from teachers where user_id is not null),
    'institutes', (select count(*) from institutes where owner_id is not null),
    'offers_live', (select count(*) from offerings o where o.active and not o.moderation_hidden and o.review_status = 'approved'
                     and (o.teacher_id in (select id from teachers where user_id is not null) or o.institute_id in (select id from institutes where owner_id is not null))),
    'paid_30d', (select coalesce(sum(price), 0) from bookings where pay_status = 'paid' and paid_at > now() - interval '30 days'),
    'open_reports', (select count(*) from reports where status = 'open'),
    'top_teachers', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select coalesce(t.name, i.name) name, count(*) n
          from bookings b join offerings o on o.id = b.offering_id
          left join teachers t on t.id = coalesce(o.teacher_id, o.course_teacher_id) and t.user_id is not null
          left join institutes i on i.id = o.institute_id and i.owner_id is not null
         where b.created_at > now() - interval '30 days' and b.status in ('pending','confirmed') and coalesce(t.name, i.name) is not null
         group by 1 order by 2 desc limit 3) x)
  ) into v;
  return v;
end $$;

-- Admin fixes an offer's title (e.g. a phone number in it) without the reject-and-wait round trip.
create or replace function public.admin_edit_offer(p_offering uuid, p_title text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_title text := nullif(trim(p_title), ''); v_owner uuid;
begin
  if not is_admin() then raise exception 'للمدير فقط'; end if;
  if v_title is null or char_length(v_title) < 3 then raise exception 'العنوان قصير جداً'; end if;
  select * into o from offerings where id = p_offering;
  if not found then raise exception 'العرض غير موجود'; end if;
  update offerings set title = v_title where id = o.id;   -- admins pass the review trigger
  v_owner := offering_owner_user(o.id);
  if v_owner is not null and v_title is distinct from o.title then
    insert into notifications (user_id, kind, body, link)
    values (v_owner, 'review', format('عدّلت الإدارة عنوان عرضك إلى «%s»%s', v_title, coalesce('. ' || nullif(trim(p_reason), ''), '.')), '/manage/course/' || o.id);
  end if;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), 'offering', o.id, 'edit_title', coalesce(nullif(trim(p_reason), ''), o.title || ' → ' || v_title));
end $$;

revoke execute on function public.admin_find_bookings, public.admin_cancel_booking, public.admin_set_payment,
  public.admin_message, public.admin_stats, public.admin_edit_offer from anon, public;
grant execute on function public.admin_find_bookings, public.admin_cancel_booking, public.admin_set_payment,
  public.admin_message, public.admin_stats, public.admin_edit_offer to authenticated;
