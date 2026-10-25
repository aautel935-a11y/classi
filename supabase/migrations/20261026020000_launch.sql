-- Classi: ready for launch.
--  1. Teacher/institute subscriptions (paid to the platform by Bit, activated by the admin)
--  2. Real ratings after lessons, with the teacher's reply
--  3. Launch switches: hide the demo data, require subscriptions
--  4. Delete my account

-- ================= settings the admin controls =================
create table if not exists public.app_settings (key text primary key, value text not null, updated_at timestamptz not null default now());
alter table public.app_settings enable row level security;
create policy "everyone reads settings" on public.app_settings for select using (true);
grant select on public.app_settings to anon, authenticated;
insert into public.app_settings (key, value) values ('subscriptions_required', 'false'), ('platform_bit', '') on conflict do nothing;

create or replace function public.setting(p_key text) returns text
language sql stable security definer set search_path = public as $$ select value from app_settings where key = p_key $$;

create or replace function public.admin_set_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := trim(coalesce(p_value, ''));
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_key not in ('subscriptions_required','platform_bit') then raise exception 'إعداد غير معروف'; end if;
  if p_key = 'platform_bit' and v <> '' then
    v := clean_phone(v);
    if v is null then raise exception 'رقم Bit غير صحيح'; end if;
  end if;
  if p_key = 'subscriptions_required' and v not in ('true','false') then raise exception 'قيمة غير صالحة'; end if;
  insert into app_settings (key, value, updated_at) values (p_key, v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

-- ================= 1. subscriptions =================
create table if not exists public.plans (
  code   text primary key,
  name   text not null,
  months int  not null check (months between 1 and 36),
  price  int  not null check (price >= 0),
  active boolean not null default true,
  sort   int not null default 0
);
alter table public.plans enable row level security;
create policy "everyone reads plans" on public.plans for select using (true);
grant select on public.plans to anon, authenticated;
insert into public.plans (code, name, months, price, sort) values
  ('m1',  'شهر',       1, 170, 1),
  ('m3',  '3 أشهر',    3, 280, 2),
  ('m6',  '6 أشهر',    6, 500, 3),
  ('y1',  'سنة',      12, 900, 4)
on conflict (code) do nothing;

create table if not exists public.subscriptions (
  id           uuid primary key default gen_random_uuid(),
  teacher_id   uuid references public.teachers(id) on delete cascade,
  institute_id uuid references public.institutes(id) on delete cascade,
  plan_code    text references public.plans(code),
  months       int not null,
  price        int not null,
  status       text not null default 'pending' check (status in ('pending','reported','active','rejected','cancelled')),
  starts_at    timestamptz,
  ends_at      timestamptz,
  note         text,
  reported_at  timestamptz,
  created_at   timestamptz not null default now(),
  check ((teacher_id is null) <> (institute_id is null))
);
create index if not exists subscriptions_owner on public.subscriptions (teacher_id, institute_id, status);
alter table public.subscriptions enable row level security;
create policy "owner or admin reads subscriptions" on public.subscriptions for select
  using (is_admin()
      or exists (select 1 from teachers t where t.id = teacher_id and t.user_id = auth.uid())
      or exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()));
grant select on public.subscriptions to authenticated;

-- End of the paid period (null = none).
create or replace function public.paid_until(p_teacher uuid, p_institute uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
  select max(ends_at) from subscriptions
   where status = 'active' and ((p_teacher is not null and teacher_id = p_teacher) or (p_institute is not null and institute_id = p_institute))
$$;

-- May this teacher/institute appear to students right now?
-- Demo rows (no account) are governed by the admin's demo switch instead.
create or replace function public.owner_has_access(p_teacher uuid, p_institute uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(setting('subscriptions_required'), 'false') <> 'true'
      or (p_teacher is not null and (select user_id is null from teachers where id = p_teacher))
      or (p_institute is not null and (select owner_id is null from institutes where id = p_institute))
      or coalesce(paid_until(p_teacher, p_institute) > now(), false)
$$;

create or replace function public.offering_owner_verified(p_offering uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select review_status = 'approved' from offerings where id = p_offering), false) and coalesce(
    (select t.verify = 'verified' and not t.moderation_hidden and (t.user_id is null or is_active_user(t.user_id)) and owner_has_access(t.id, null)
       from offerings o join teachers t on t.id = o.teacher_id where o.id = p_offering),
    (select i.verify = 'verified' and not i.moderation_hidden and (i.owner_id is null or is_active_user(i.owner_id)) and owner_has_access(null, i.id)
       from offerings o join institutes i on i.id = o.institute_id where o.id = p_offering),
    false)
$$;

drop policy if exists "read teachers" on public.teachers;
create policy "read teachers" on public.teachers for select
  using ((verify = 'verified' and not moderation_hidden and (user_id is null or is_active_user(user_id)) and owner_has_access(id, null)) or user_id = auth.uid());
drop policy if exists "read institutes" on public.institutes;
create policy "read institutes" on public.institutes for select
  using ((verify = 'verified' and not moderation_hidden and (owner_id is null or is_active_user(owner_id)) and owner_has_access(null, id)) or owner_id = auth.uid());

-- Teacher/institute picks a plan; pays the platform by Bit; taps "I transferred".
create or replace function public.request_subscription(p_plan text) returns uuid
language plpgsql security definer set search_path = public as $$
declare p plans%rowtype; v_t uuid; v_i uuid; v_id uuid; v_name text;
begin
  select * into p from plans where code = p_plan and active;
  if not found then raise exception 'الباقة غير متاحة'; end if;
  select id, name into v_t, v_name from teachers where user_id = auth.uid() limit 1;
  if v_t is null then select id, name into v_i, v_name from institutes where owner_id = auth.uid() limit 1; end if;
  if v_t is null and v_i is null then raise exception 'أنشئ ملف المعلم أو المعهد أولاً'; end if;
  -- one open request at a time: replace an unpaid one
  update subscriptions set status = 'cancelled'
   where status = 'pending' and ((v_t is not null and teacher_id = v_t) or (v_i is not null and institute_id = v_i));
  if exists (select 1 from subscriptions where status = 'reported' and ((v_t is not null and teacher_id = v_t) or (v_i is not null and institute_id = v_i))) then
    raise exception 'لديك تحويل بانتظار تأكيد الإدارة';
  end if;
  insert into subscriptions (teacher_id, institute_id, plan_code, months, price) values (v_t, v_i, p.code, p.months, p.price) returning id into v_id;
  return v_id;
end $$;

create or replace function public.report_subscription_payment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s subscriptions%rowtype; v_name text;
begin
  select * into s from subscriptions where id = p_id;
  if not found or not (exists (select 1 from teachers t where t.id = s.teacher_id and t.user_id = auth.uid())
                       or exists (select 1 from institutes i where i.id = s.institute_id and i.owner_id = auth.uid())) then
    raise exception 'الطلب غير موجود';
  end if;
  if s.status <> 'pending' then raise exception 'تم الإبلاغ عن هذا الطلب سابقاً'; end if;
  update subscriptions set status = 'reported', reported_at = now() where id = p_id;
  select coalesce((select name from teachers where id = s.teacher_id), (select name from institutes where id = s.institute_id)) into v_name;
  perform notify_admins(format('%s حوّل %s ₪ لاشتراك %s أشهر. أكّد الاستلام لتفعيله.', v_name, s.price, s.months), '/admin?tab=subs');
end $$;

-- Admin: activate after the money arrived (or reject), or grant free months (launch offer).
create or replace function public.admin_activate_subscription(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare s subscriptions%rowtype; v_start timestamptz; v_owner uuid;
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  select * into s from subscriptions where id = p_id;
  if not found or s.status not in ('pending','reported') then raise exception 'الطلب غير موجود أو تمت معالجته'; end if;
  v_owner := coalesce((select user_id from teachers where id = s.teacher_id), (select owner_id from institutes where id = s.institute_id));
  if p_approve then
    v_start := greatest(now(), coalesce(paid_until(s.teacher_id, s.institute_id), now()));
    update subscriptions set status = 'active', starts_at = v_start, ends_at = v_start + make_interval(months => s.months), note = nullif(trim(p_note), '') where id = p_id;
    insert into notifications (user_id, kind, body, link)
    select v_owner, 'subscription', format('تم تفعيل اشتراكك حتى %s. عروضك ظاهرة للطلاب.', to_char((v_start + make_interval(months => s.months)) at time zone 'Asia/Jerusalem', 'DD/MM/YYYY')),
           case when s.teacher_id is not null then '/teach#subscription' else '/manage#subscription' end
     where v_owner is not null;
  else
    update subscriptions set status = 'rejected', note = nullif(trim(p_note), '') where id = p_id;
    insert into notifications (user_id, kind, body, link)
    select v_owner, 'subscription', format('لم نجد تحويل الاشتراك (%s ₪).%s تواصل معنا: classi@torix.click', s.price, coalesce(' «' || nullif(trim(p_note), '') || '»', '')),
           case when s.teacher_id is not null then '/teach#subscription' else '/manage#subscription' end
     where v_owner is not null;
  end if;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), 'subscription', p_id, case when p_approve then 'subscription_activate' else 'subscription_reject' end, p_note);
end $$;

create or replace function public.admin_grant_subscription(p_teacher uuid, p_institute uuid, p_months int, p_note text default null) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v_start timestamptz; v_end timestamptz; v_id uuid; v_owner uuid;
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_months not between 1 and 36 then raise exception 'عدد الأشهر بين 1 و36'; end if;
  if (p_teacher is null) = (p_institute is null) then raise exception 'اختر معلماً أو معهداً'; end if;
  v_start := greatest(now(), coalesce(paid_until(p_teacher, p_institute), now()));
  v_end := v_start + make_interval(months => p_months);
  insert into subscriptions (teacher_id, institute_id, months, price, status, starts_at, ends_at, note)
  values (p_teacher, p_institute, p_months, 0, 'active', v_start, v_end, coalesce(nullif(trim(p_note), ''), 'هدية من الإدارة')) returning id into v_id;
  v_owner := coalesce((select user_id from teachers where id = p_teacher), (select owner_id from institutes where id = p_institute));
  insert into notifications (user_id, kind, body, link)
  select v_owner, 'subscription', format('حصلت على %s أشهر مجاناً من Classi. اشتراكك فعّال حتى %s.', p_months, to_char(v_end at time zone 'Asia/Jerusalem', 'DD/MM/YYYY')),
         case when p_teacher is not null then '/teach#subscription' else '/manage#subscription' end
   where v_owner is not null;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason) values (auth.uid(), 'subscription', v_id, 'subscription_grant', p_note);
  return v_end;
end $$;

create or replace function public.admin_set_plan(p_code text, p_price int, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_price < 0 then raise exception 'سعر غير صالح'; end if;
  update plans set price = p_price, active = p_active where code = p_code;
end $$;

-- Admin overview: requests to act on, and everyone's paid-until date.
create or replace function public.admin_subscriptions()
returns table (kind text, owner_id uuid, owner_name text, has_account boolean, paid_until timestamptz,
               request_id uuid, request_status text, request_price int, request_months int, requested_at timestamptz)
language sql stable security definer set search_path = public as $$
  select 'teacher', t.id, t.name, t.user_id is not null, paid_until(t.id, null), r.id, r.status, r.price, r.months, coalesce(r.reported_at, r.created_at)
    from teachers t
    left join lateral (select * from subscriptions s where s.teacher_id = t.id and s.status in ('pending','reported') order by created_at desc limit 1) r on true
   where is_admin() and t.verify = 'verified'
  union all
  select 'institute', i.id, i.name, i.owner_id is not null, paid_until(null, i.id), r.id, r.status, r.price, r.months, coalesce(r.reported_at, r.created_at)
    from institutes i
    left join lateral (select * from subscriptions s where s.institute_id = i.id and s.status in ('pending','reported') order by created_at desc limit 1) r on true
   where is_admin() and i.verify = 'verified'
  order by 7 nulls last, 5 nulls first, 3
$$;

-- Daily: warn 7 days and 1 day before the end, and on the day it ends.
create or replace function public.subscription_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0; v_key text; v_days int;
begin
  if coalesce(setting('subscriptions_required'), 'false') <> 'true' then return 0; end if;
  for r in
    select t.user_id u, paid_until(t.id, null) e, '/teach#subscription' link from teachers t where t.user_id is not null and t.verify = 'verified'
    union all
    select i.owner_id, paid_until(null, i.id), '/manage#subscription' from institutes i where i.owner_id is not null and i.verify = 'verified'
  loop
    if r.e is null then continue; end if;
    v_days := ceil(extract(epoch from (r.e - now())) / 86400)::int;
    if v_days not in (7, 1, 0) then continue; end if;
    v_key := format('sub:%s:%s:%s', r.u, to_char(r.e, 'YYYYMMDD'), v_days);
    insert into reminder_log (key) values (v_key) on conflict do nothing;
    if not found then continue; end if;
    insert into notifications (user_id, kind, body, link) values (r.u, 'subscription',
      case when v_days = 0 then 'انتهى اشتراكك في Classi، وعروضك لم تعد ظاهرة للطلاب. جدّد الاشتراك لتعود فوراً.'
           else format('اشتراكك في Classi ينتهي خلال %s %s. جدّده حتى تبقى عروضك ظاهرة.', v_days, case when v_days = 1 then 'يوم' else 'أيام' end) end,
      r.link);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ================= 2. ratings =================
alter table public.reviews add column if not exists user_id uuid references public.profiles(id) on delete set null;
alter table public.reviews add column if not exists child_id uuid references public.children(id) on delete set null;
alter table public.reviews add column if not exists teacher_id uuid references public.teachers(id) on delete cascade;
alter table public.reviews add column if not exists institute_id uuid references public.institutes(id) on delete cascade;
alter table public.reviews add column if not exists author_name text;
alter table public.reviews add column if not exists reply text check (char_length(reply) <= 600);
alter table public.reviews add column if not exists replied_at timestamptz;
alter table public.reviews add column if not exists hidden boolean not null default false;
alter table public.reviews add column if not exists updated_at timestamptz not null default now();
alter table public.reviews drop constraint if exists reviews_body_len;
alter table public.reviews add constraint reviews_body_len check (body is null or char_length(body) <= 600);
-- one review per family member per teacher/institute (they can update it)
create unique index if not exists reviews_one_per_owner
  on public.reviews (user_id, coalesce(child_id, '00000000-0000-0000-0000-000000000000'::uuid),
                     coalesce(teacher_id, institute_id));
drop policy if exists "read reviews" on public.reviews;
create policy "read reviews" on public.reviews for select using (not hidden or user_id = auth.uid() or is_admin());
drop policy if exists "review own booking" on public.reviews;

-- Ratings on the profile follow the real reviews (once a teacher has any).
create or replace function public.recount_rating(p_teacher uuid, p_institute uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_avg numeric; v_n int;
begin
  select round(avg(stars)::numeric, 1), count(*) into v_avg, v_n from reviews
   where not hidden and ((p_teacher is not null and teacher_id = p_teacher) or (p_institute is not null and institute_id = p_institute));
  if p_teacher is not null then
    update teachers set rating = coalesce(v_avg, 0), reviews_count = v_n where id = p_teacher and (v_n > 0 or user_id is not null);
  else
    update institutes set rating = coalesce(v_avg, 0), reviews_count = v_n where id = p_institute and (v_n > 0 or owner_id is not null);
  end if;
end $$;

create or replace function public.reviews_recount() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op <> 'INSERT' then perform recount_rating(old.teacher_id, old.institute_id); end if;
  if tg_op <> 'DELETE' then perform recount_rating(new.teacher_id, new.institute_id); end if;
  return null;
end $$;
drop trigger if exists reviews_recount on public.reviews;
create trigger reviews_recount after insert or update or delete on public.reviews
  for each row execute function public.reviews_recount();

-- Leave or update a rating: only after a confirmed lesson that already happened.
create or replace function public.leave_review(p_booking uuid, p_stars int, p_body text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare b record; v_id uuid; v_owner uuid; v_new boolean;
begin
  if p_stars not between 1 and 5 then raise exception 'اختر من 1 إلى 5 نجوم'; end if;
  select bk.id, bk.child_id, o.teacher_id, o.institute_id, o.title,
         coalesce(bk.starts_at, s.starts_at, (select min(x.starts_at) from sessions x where x.offering_id = o.id and not x.cancelled)) at
    into b
    from bookings bk join offerings o on o.id = bk.offering_id left join sessions s on s.id = bk.session_id
   where bk.id = p_booking and bk.booked_by = auth.uid() and bk.status = 'confirmed';
  if b.id is null then raise exception 'يمكنك تقييم حصة حجزتها فقط'; end if;
  if b.at is null or b.at > now() then raise exception 'يمكنك التقييم بعد الحصة الأولى'; end if;
  select id into v_id from reviews where user_id = auth.uid() and child_id is not distinct from b.child_id
     and coalesce(teacher_id, institute_id) = coalesce(b.teacher_id, b.institute_id);
  v_new := v_id is null;
  if v_new then
    insert into reviews (booking_id, stars, body, user_id, child_id, teacher_id, institute_id, author_name)
    values (b.id, p_stars, nullif(trim(p_body), ''), auth.uid(), b.child_id, b.teacher_id, b.institute_id,
            array_to_string((string_to_array(trim(coalesce((select full_name from profiles where id = auth.uid()), '')), ' '))[1:2], ' '))
    returning id into v_id;
  else
    update reviews set stars = p_stars, body = nullif(trim(p_body), ''), updated_at = now() where id = v_id;
  end if;
  v_owner := coalesce((select user_id from teachers where id = b.teacher_id), (select owner_id from institutes where id = b.institute_id));
  if v_owner is not null and v_new then
    insert into notifications (user_id, kind, body, link)
    values (v_owner, 'review_new', format('تقييم جديد %s نجوم: %s%s', p_stars, b.title, coalesce(' «' || left(nullif(trim(p_body), ''), 60) || '»', '')),
            case when b.teacher_id is not null then '/teach#reviews' else '/manage#reviews' end);
  end if;
  return v_id;
end $$;

create or replace function public.reply_review(p_review uuid, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
declare r reviews%rowtype;
begin
  select * into r from reviews where id = p_review;
  if not found or not (exists (select 1 from teachers t where t.id = r.teacher_id and t.user_id = auth.uid())
                       or exists (select 1 from institutes i where i.id = r.institute_id and i.owner_id = auth.uid())) then
    raise exception 'لا تملك صلاحية على هذا التقييم';
  end if;
  update reviews set reply = nullif(trim(p_reply), ''), replied_at = case when nullif(trim(p_reply), '') is null then null else now() end where id = p_review;
end $$;

create or replace function public.admin_hide_review(p_review uuid, p_hidden boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  update reviews set hidden = p_hidden where id = p_review;
  insert into moderation_actions (admin_id, target_type, target_id, action) values (auth.uid(), 'review', p_review, case when p_hidden then 'hide' else 'unhide' end);
end $$;

-- Two hours after a family's lesson, ask once (per teacher, at most monthly) for a rating.
create or replace function public.review_prompts() returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0;
begin
  for r in
    select distinct on (b.booked_by, coalesce(o.teacher_id, o.institute_id))
           b.id booking_id, b.booked_by, o.teacher_id, o.institute_id, coalesce(t.name, i.name) owner_name
      from bookings b join offerings o on o.id = b.offering_id
      left join sessions s on s.id = b.session_id
      left join teachers t on t.id = o.teacher_id left join institutes i on i.id = o.institute_id
     where b.status = 'confirmed'
       and coalesce(b.starts_at, s.starts_at) + make_interval(mins => coalesce(b.minutes, 60)) + interval '2 hours' between now() - interval '6 hours' and now()
       and not exists (select 1 from reviews v where v.user_id = b.booked_by and coalesce(v.teacher_id, v.institute_id) = coalesce(o.teacher_id, o.institute_id))
     order by b.booked_by, coalesce(o.teacher_id, o.institute_id), b.starts_at desc
  loop
    if exists (select 1 from notifications n where n.user_id = r.booked_by and n.kind = 'review_prompt'
                 and n.body like '%' || r.owner_name || '%' and n.created_at > now() - interval '30 days') then
      continue;
    end if;
    insert into notifications (user_id, kind, body, link)
    values (r.booked_by, 'review_prompt', format('كيف كانت الحصة مع %s؟ تقييمك يساعد عائلات أخرى.', r.owner_name), '/review?booking=' || r.booking_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ================= 3. launch switches =================
-- Hide or show every demo teacher/institute (rows that belong to no account).
create or replace function public.admin_demo_visible(p_visible boolean) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int; v_m int;
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  update teachers set moderation_hidden = not p_visible where user_id is null;
  get diagnostics v_n = row_count;
  update institutes set moderation_hidden = not p_visible where owner_id is null;
  get diagnostics v_m = row_count;
  insert into app_settings (key, value) values ('demo_visible', p_visible::text)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into moderation_actions (admin_id, target_type, target_id, action) values (auth.uid(), 'settings', auth.uid(), case when p_visible then 'demo_show' else 'demo_hide' end);
  return v_n + v_m;
end $$;

-- ================= 4. delete my account =================
create or replace function public.delete_my_account(p_confirm text) returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid(); b record;
begin
  if v_uid is null then raise exception 'سجّل الدخول أولاً'; end if;
  if trim(coalesce(p_confirm, '')) <> 'احذف' then raise exception 'اكتب كلمة «احذف» للتأكيد'; end if;
  perform set_config('classi.bypass_review', 'on', true);

  -- Future lessons booked by this account are cancelled and the teachers told.
  for b in select bk.id from bookings bk left join sessions s on s.id = bk.session_id
            where bk.booked_by = v_uid and bk.status in ('pending','confirmed') and coalesce(bk.starts_at, s.starts_at, now() + interval '1 day') > now() loop
    update bookings set status = 'cancelled' where id = b.id;
  end loop;
  update recurring_series set status = 'cancelled', cancelled_at = now() where booked_by = v_uid and status <> 'cancelled';

  -- A teacher or institute leaving: their profile and offers disappear, their students are told.
  insert into notifications (user_id, kind, body, link)
  select distinct bk.booked_by, 'booking_cancelled', format('أُغلق حساب %s في Classi، وأُلغيت الحصص القادمة معه.', coalesce(t.name, i.name)), '/search'
    from bookings bk join offerings o on o.id = bk.offering_id
    left join teachers t on t.id = o.teacher_id left join institutes i on i.id = o.institute_id
    left join sessions s on s.id = bk.session_id
   where (t.user_id = v_uid or i.owner_id = v_uid) and bk.status in ('pending','confirmed')
     and coalesce(bk.starts_at, s.starts_at, now() + interval '1 day') > now() and bk.booked_by <> v_uid;
  update bookings bk set status = 'cancelled' from offerings o
   where o.id = bk.offering_id and bk.status in ('pending','confirmed')
     and (o.teacher_id in (select id from teachers where user_id = v_uid) or o.institute_id in (select id from institutes where owner_id = v_uid));
  update offerings set active = false
   where teacher_id in (select id from teachers where user_id = v_uid) or institute_id in (select id from institutes where owner_id = v_uid);
  update teachers set moderation_hidden = true, verify = 'rejected', bio = '', photo_url = null, intro_video_url = null where user_id = v_uid;
  update institutes set moderation_hidden = true, verify = 'rejected', bio = '', logo_url = null where owner_id = v_uid;
  delete from pay_numbers where teacher_id in (select id from teachers where user_id = v_uid) or institute_id in (select id from institutes where owner_id = v_uid);
  delete from push_subscriptions where user_id = v_uid;

  -- The sign-in account goes; the profile and personal rows follow by cascade.
  delete from auth.users where id = v_uid;
end $$;

-- New notification kinds that should buzz the phone.
create or replace function public.notifications_mark_push() returns trigger
language plpgsql as $$
begin
  new.want_push := new.kind in ('reminder','reminder_soon','booking_answer','booking_request','booking_new','booking_cancelled',
                                'schedule_changed','waitlist_open','waitlist_answer','waitlist_join','verified','message',
                                'lesson_report','report_due','payment_reported','payment_answer','review_needed','review_answer',
                                'subscription','review_new','review_prompt');
  return new;
end $$;

revoke execute on function public.admin_set_setting, public.request_subscription, public.report_subscription_payment,
  public.admin_activate_subscription, public.admin_grant_subscription, public.admin_set_plan, public.admin_subscriptions,
  public.subscription_reminders, public.leave_review, public.reply_review, public.admin_hide_review, public.review_prompts,
  public.admin_demo_visible, public.delete_my_account, public.recount_rating from anon, public;
grant execute on function public.admin_set_setting, public.request_subscription, public.report_subscription_payment,
  public.admin_activate_subscription, public.admin_grant_subscription, public.admin_set_plan, public.admin_subscriptions,
  public.leave_review, public.reply_review, public.admin_hide_review, public.admin_demo_visible, public.delete_my_account to authenticated;
grant execute on function public.setting, public.owner_has_access, public.paid_until to anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('classi-subscriptions', 'classi-review-prompts');
    perform cron.schedule('classi-subscriptions', '7 9 * * *', 'select public.subscription_reminders()');
    perform cron.schedule('classi-review-prompts', '*/30 * * * *', 'select public.review_prompts()');
  end if;
end $$;
