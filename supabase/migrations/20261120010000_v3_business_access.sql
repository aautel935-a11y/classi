-- Classi v3 · business access: 30-day free trial, paid subscription after it, grace period, exemptions, discounts,
-- trial-abuse guard, reminders and reports (decision of 19/11/2026). Customers always use Classi free.
--
-- Builds on the existing subscriptions (plans, request → "I transferred" → admin activates, paid_until). Payment for the
-- subscription is still recorded by hand (outside Classi). Nothing is ever deleted when access ends: the business is only
-- hidden from customers (owner_has_access), exactly as today, and comes back the moment it renews.
--
-- Nothing changes until the admin turns on the existing switch subscriptions_required (off today) — owner_has_access
-- still returns true for everyone while it is off. The trial clock for businesses that exist before launch starts at the
-- admin's launch date (setting launch_at); a business created after launch starts its trial when it is created.
--
-- State of one business, first match wins:
--   exempt    an admin exemption is running
--   active    a paid (or granted) subscription is running
--   trial     inside its free trial
--   prelaunch launch_at not set yet, or in the future (no clock is running)
--   grace     trial or subscription ended less than grace_days ago (still visible, with warnings)
--   expired   hidden from customers; data kept

insert into public.app_settings (key, value) values ('trial_days', '30'), ('grace_days', '7'), ('launch_at', '')
on conflict do nothing;

-- ================= tables =================
-- One row per business that got (or was refused) a trial after launch. Businesses from before launch have none:
-- their trial is computed from launch_at.
create table if not exists public.business_trials (
  id           uuid primary key default gen_random_uuid(),
  teacher_id   uuid unique references public.teachers(id) on delete cascade,
  institute_id uuid unique references public.institutes(id) on delete cascade,
  owner_id     uuid,
  phone_hash   text,            -- sha256 of the owner's phone digits: never the number itself
  started_at   timestamptz not null,
  ends_at      timestamptz not null,
  repeat_of    uuid,            -- the earlier trial this one repeats (same owner or same phone): no free days
  extended_days int not null default 0,
  created_at   timestamptz not null default now(),
  constraint business_trials_one_owner check ((teacher_id is null) <> (institute_id is null))
);
create index if not exists business_trials_phone on public.business_trials (phone_hash) where phone_hash is not null;
create index if not exists business_trials_owner on public.business_trials (owner_id) where owner_id is not null;

create table if not exists public.business_exemptions (
  id           uuid primary key default gen_random_uuid(),
  teacher_id   uuid references public.teachers(id) on delete cascade,
  institute_id uuid references public.institutes(id) on delete cascade,
  until        timestamptz not null,
  reason       text not null check (length(trim(reason)) >= 3),
  granted_by   uuid,
  created_at   timestamptz not null default now(),
  revoked_at   timestamptz,
  constraint business_exemptions_one_owner check ((teacher_id is null) <> (institute_id is null))
);

-- Discounts on a subscription request: the list price is kept beside the price actually asked.
alter table public.subscriptions add column if not exists list_price int;
alter table public.subscriptions add column if not exists discount_reason text;

alter table public.business_trials enable row level security;
alter table public.business_exemptions enable row level security;
revoke all on public.business_trials, public.business_exemptions from anon, authenticated;

-- ================= helpers (internal) =================
create or replace function public.access_setting_int(p_key text, p_default int) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select case when setting(p_key) ~ '^\d{1,3}$' then setting(p_key)::int else p_default end
$$;

create or replace function public.access_launch_at() returns timestamptz
language sql stable security definer set search_path = public, pg_temp as $$
  select case when coalesce(setting('launch_at'), '') ~ '^\d{4}-\d{2}-\d{2}$'
              then (setting('launch_at')::date::timestamp at time zone 'Asia/Jerusalem') end
$$;

create or replace function public.access_phone_hash(p_user uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case when length(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g')) >= 9
              then encode(sha256(convert_to(right(regexp_replace(p.phone, '\D', '', 'g'), 9), 'UTF8')), 'hex') end
    from profiles p where p.id = p_user
$$;

-- Trial end of a business: its trial row, else (created before launch) launch_at + trial_days, else null (no clock yet).
-- A repeat trial that no admin extended counts as no trial at all (so it gets no grace period either).
create or replace function public.access_trial_end(p_teacher uuid, p_institute uuid) returns timestamptz
language sql stable security definer set search_path = public, pg_temp as $$
  select case when b.id is not null then (case when b.repeat_of is not null and b.extended_days = 0 then null else b.ends_at end)
              else access_launch_at() + make_interval(days => access_setting_int('trial_days', 30)) end
    from (select 1) one
    left join lateral (select * from business_trials
                        where (p_teacher is not null and teacher_id = p_teacher) or (p_institute is not null and institute_id = p_institute)
                        limit 1) b on true
$$;

create or replace function public.access_exempt_until(p_teacher uuid, p_institute uuid) returns timestamptz
language sql stable security definer set search_path = public, pg_temp as $$
  select max(until) from business_exemptions
   where revoked_at is null and ((p_teacher is not null and teacher_id = p_teacher) or (p_institute is not null and institute_id = p_institute))
$$;

-- The state of one business (see the header). ends_at = when the current state ends (null for prelaunch/expired).
create or replace function public.business_access_state(p_teacher uuid, p_institute uuid,
  out state text, out ends_at timestamptz, out days_left int, out trial_ends_at timestamptz, out paid_until timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_ex timestamptz; v_launch timestamptz := access_launch_at(); v_grace int := access_setting_int('grace_days', 7); v_last timestamptz;
begin
  v_ex := access_exempt_until(p_teacher, p_institute);
  paid_until := public.paid_until(p_teacher, p_institute);
  trial_ends_at := access_trial_end(p_teacher, p_institute);
  if v_ex > now() then state := 'exempt'; ends_at := v_ex;
  elsif paid_until > now() then state := 'active'; ends_at := paid_until;
  elsif trial_ends_at > now() then state := 'trial'; ends_at := trial_ends_at;
  elsif (v_launch is null or v_launch > now())
        and not exists (select 1 from business_trials where (p_teacher is not null and teacher_id = p_teacher) or (p_institute is not null and institute_id = p_institute)) then
    state := 'prelaunch'; ends_at := null;
  else
    v_last := greatest(coalesce(paid_until, '-infinity'), coalesce(trial_ends_at, '-infinity'), coalesce(v_ex, '-infinity'));
    if v_last > '-infinity' and v_last + make_interval(days => v_grace) > now() then
      state := 'grace'; ends_at := v_last + make_interval(days => v_grace);
    else state := 'expired'; ends_at := null; end if;
  end if;
  days_left := case when ends_at is null then null else greatest(ceil(extract(epoch from (ends_at - now())) / 86400)::int, 0) end;
end $$;

revoke all on function public.access_setting_int(text, int), public.access_launch_at(), public.access_phone_hash(uuid),
  public.access_trial_end(uuid, uuid), public.access_exempt_until(uuid, uuid), public.business_access_state(uuid, uuid)
  from public, anon, authenticated;

-- ================= the trial starts with the business =================
-- After launch, a new business (or a demo profile claimed by an account) gets its trial row. The same owner account or
-- the same phone already used a trial on another business → a trial of 0 days (repeat_of set; the admin can extend).
-- Before launch nothing is recorded: launch_at sets everyone's clock. Never raises: a failure here must not block signup.
create or replace function public.access_start_trial() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner uuid; v_hash text; v_prev uuid; v_days int; v_start timestamptz := now(); v_launch timestamptz;
begin
  begin
    v_launch := access_launch_at();
    if v_launch is null or v_launch > now() then return new; end if;
    v_owner := (to_jsonb(new) ->> case when tg_table_name = 'teachers' then 'user_id' else 'owner_id' end)::uuid;
    if v_owner is null then return new; end if;
    if exists (select 1 from business_trials where (tg_table_name = 'teachers' and teacher_id = new.id) or (tg_table_name = 'institutes' and institute_id = new.id)) then
      return new;
    end if;
    v_hash := access_phone_hash(v_owner);
    select id into v_prev from business_trials
     where (owner_id = v_owner or (v_hash is not null and phone_hash = v_hash))
     order by created_at limit 1;
    v_days := case when v_prev is null then access_setting_int('trial_days', 30) else 0 end;
    insert into business_trials (teacher_id, institute_id, owner_id, phone_hash, started_at, ends_at, repeat_of)
    values (case when tg_table_name = 'teachers' then new.id end, case when tg_table_name = 'institutes' then new.id end,
            v_owner, v_hash, v_start, v_start + make_interval(days => v_days), v_prev);
  exception when others then
    raise warning 'access_start_trial skipped: %', sqlerrm;
  end;
  return new;
end $$;
revoke all on function public.access_start_trial() from public, anon, authenticated;
drop trigger if exists teachers_start_trial on public.teachers;
create trigger teachers_start_trial after insert or update of user_id on public.teachers
  for each row when (new.user_id is not null) execute function public.access_start_trial();
drop trigger if exists institutes_start_trial on public.institutes;
create trigger institutes_start_trial after insert or update of owner_id on public.institutes
  for each row when (new.owner_id is not null) execute function public.access_start_trial();

-- ================= visibility (same switch as before) =================
-- While subscriptions_required is off: everyone visible (unchanged). On: visible in exempt / active / trial / prelaunch /
-- grace; hidden when expired. Demo rows (no account) follow the admin's demo switch, as before.
create or replace function public.owner_has_access(p_teacher uuid, p_institute uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(setting('subscriptions_required'), 'false') <> 'true'
      or (p_teacher is not null and (select user_id is null from teachers where id = p_teacher))
      or (p_institute is not null and (select owner_id is null from institutes where id = p_institute))
      or (select state <> 'expired' from business_access_state(p_teacher, p_institute))
$$;

-- ================= owner =================
create or replace function public.my_access_state()
returns table (kind text, business_id uuid, state text, ends_at timestamptz, days_left int, trial_ends_at timestamptz,
               paid_until timestamptz, required boolean, grace_days int)
language sql stable security definer set search_path = public, pg_temp as $$
  select 'teacher', t.id, s.state, s.ends_at, s.days_left, s.trial_ends_at, s.paid_until,
         coalesce(setting('subscriptions_required'), 'false') = 'true', access_setting_int('grace_days', 7)
    from teachers t, business_access_state(t.id, null) s where t.user_id = auth.uid() and auth.uid() is not null
  union all
  select 'institute', i.id, s.state, s.ends_at, s.days_left, s.trial_ends_at, s.paid_until,
         coalesce(setting('subscriptions_required'), 'false') = 'true', access_setting_int('grace_days', 7)
    from institutes i, business_access_state(null, i.id) s where i.owner_id = auth.uid() and auth.uid() is not null
$$;

-- ================= admin =================
-- Settings: exactly the keys and checks of 20261031020000_phase3_performance_settings.sql (the latest version), plus
-- trial_days (0–90), grace_days (0–60) and launch_at (YYYY-MM-DD or empty; locked once a post-launch trial exists).
-- Every change is now written to audit_log.
create or replace function public.admin_set_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := trim(coalesce(p_value, '')); v_n int;
        -- numeric settings: key -> allowed range
        v_ranges jsonb := '{"min_lead_minutes":[0,1440],"max_open_bookings_per_offer":[1,50],"sms_daily_cap_per_user":[0,50],
                            "sms_daily_cap":[0,5000],"otp_per_hour":[1,20],"otp_per_day":[1,100],"staff_invites_per_day":[1,100],
                            "trial_days":[0,90],"grace_days":[0,60]}';
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_key in ('platform_bit','support_whatsapp') then
    if v <> '' then
      v := clean_phone(v);
      if v is null then raise exception 'رقم الجوال غير صحيح'; end if;
    end if;
  elsif p_key = 'subscriptions_required' then
    if v not in ('true','false') then raise exception 'قيمة غير صالحة'; end if;
  elsif p_key = 'launch_at' then
    if v <> '' then
      if v !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'التاريخ بصيغة YYYY-MM-DD'; end if;
      perform v::date;
    end if;
    if exists (select 1 from business_trials) then raise exception 'بدأت تجارب بعد الإطلاق، ولا يمكن تغيير تاريخه الآن'; end if;
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
  insert into audit_log (actor, action, entity, after) values (auth.uid(), 'setting_set', 'setting', jsonb_build_object(p_key, v));
end $$;

-- Every business with its state, for the admin's subscriptions tab.
create or replace function public.admin_business_access()
returns table (kind text, business_id uuid, name text, has_account boolean, state text, ends_at timestamptz, days_left int,
               trial_ends_at timestamptz, paid_until timestamptz, repeat_trial boolean, exempt_until timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select 'teacher', t.id, t.name, t.user_id is not null, s.state, s.ends_at, s.days_left, s.trial_ends_at, s.paid_until,
         exists (select 1 from business_trials b where b.teacher_id = t.id and b.repeat_of is not null), access_exempt_until(t.id, null)
    from teachers t, business_access_state(t.id, null) s where is_admin() and t.verify = 'verified'
  union all
  select 'institute', i.id, i.name, i.owner_id is not null, s.state, s.ends_at, s.days_left, s.trial_ends_at, s.paid_until,
         exists (select 1 from business_trials b where b.institute_id = i.id and b.repeat_of is not null), access_exempt_until(null, i.id)
    from institutes i, business_access_state(null, i.id) s where is_admin() and i.verify = 'verified'
  order by 5, 7 nulls last, 3
$$;

-- Extend a trial by days (also how an admin gives a repeat trial its days after checking it).
create or replace function public.admin_extend_trial(p_teacher uuid, p_institute uuid, p_days int, p_reason text) returns timestamptz
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_end timestamptz; v_old timestamptz;
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if (p_teacher is null) = (p_institute is null) then raise exception 'اختر معلماً أو معهداً'; end if;
  if p_days not between 1 and 90 then raise exception 'عدد الأيام بين 1 و90'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'اكتب السبب'; end if;
  v_old := access_trial_end(p_teacher, p_institute);
  if not exists (select 1 from business_trials where (p_teacher is not null and teacher_id = p_teacher) or (p_institute is not null and institute_id = p_institute)) then
    -- a business from before launch: give it its own row, starting from the computed trial
    insert into business_trials (teacher_id, institute_id, owner_id, started_at, ends_at)
    values (p_teacher, p_institute,
            coalesce((select user_id from teachers where id = p_teacher), (select owner_id from institutes where id = p_institute)),
            coalesce(access_launch_at(), now()), greatest(coalesce(v_old, now()), now()));
  end if;
  update business_trials set ends_at = greatest(ends_at, now()) + make_interval(days => p_days), extended_days = extended_days + p_days
   where (p_teacher is not null and teacher_id = p_teacher) or (p_institute is not null and institute_id = p_institute)
  returning ends_at into v_end;
  insert into audit_log (actor, teacher_id, institute_id, action, entity, before, after, reason)
  values (auth.uid(), p_teacher, p_institute, 'trial_extend', 'access', jsonb_build_object('trial_ends_at', v_old),
          jsonb_build_object('trial_ends_at', v_end, 'days', p_days), trim(p_reason));
  return v_end;
end $$;

-- Exemption until a date (a partner, a charity, a pilot customer). Revocable.
create or replace function public.admin_set_exemption(p_teacher uuid, p_institute uuid, p_until date, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if (p_teacher is null) = (p_institute is null) then raise exception 'اختر معلماً أو معهداً'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'اكتب السبب'; end if;
  update business_exemptions set revoked_at = now()
   where revoked_at is null and ((p_teacher is not null and teacher_id = p_teacher) or (p_institute is not null and institute_id = p_institute));
  if p_until is not null then
    if p_until <= (now() at time zone 'Asia/Jerusalem')::date then raise exception 'تاريخ الإعفاء في الماضي'; end if;
    insert into business_exemptions (teacher_id, institute_id, until, reason, granted_by)
    values (p_teacher, p_institute, (p_until + 1)::timestamp at time zone 'Asia/Jerusalem', trim(p_reason), auth.uid());
  end if;
  insert into audit_log (actor, teacher_id, institute_id, action, entity, after, reason)
  values (auth.uid(), p_teacher, p_institute, case when p_until is null then 'exemption_revoke' else 'exemption_set' end, 'access',
          jsonb_build_object('until', p_until), trim(p_reason));
end $$;

-- Discount on an open request (pending or reported): the price the business pays, with the reason; the list price stays.
create or replace function public.admin_discount_request(p_id uuid, p_price int, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s subscriptions%rowtype;
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  select * into s from subscriptions where id = p_id for update;
  if not found or s.status not in ('pending','reported') then raise exception 'الطلب غير موجود أو تمت معالجته'; end if;
  if p_price is null or p_price < 0 or p_price > coalesce(s.list_price, s.price) then raise exception 'السعر بين 0 والسعر الأصلي'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'اكتب سبب الخصم'; end if;
  update subscriptions set list_price = coalesce(list_price, price), price = p_price, discount_reason = trim(p_reason) where id = p_id;
  insert into audit_log (actor, teacher_id, institute_id, action, entity, entity_id, before, after, reason)
  values (auth.uid(), s.teacher_id, s.institute_id, 'subscription_discount', 'subscription', p_id,
          jsonb_build_object('price', s.price), jsonb_build_object('price', p_price), trim(p_reason));
end $$;

-- Plans the admin can add or change (name, months, price, active, order). Existing requests keep their own price.
create or replace function public.admin_upsert_plan(p_code text, p_name text, p_months int, p_price int, p_active boolean, p_sort int default 0) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_before jsonb;
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if coalesce(p_code, '') !~ '^[a-z0-9_]{1,20}$' then raise exception 'رمز الباقة: أحرف إنجليزية صغيرة وأرقام'; end if;
  if length(trim(coalesce(p_name, ''))) not between 2 and 40 then raise exception 'اسم الباقة غير صالح'; end if;
  if p_months not between 1 and 36 then raise exception 'عدد الأشهر بين 1 و36'; end if;
  if p_price is null or p_price < 0 or p_price > 100000 then raise exception 'سعر غير صالح'; end if;
  select to_jsonb(p) into v_before from plans p where code = p_code;
  insert into plans (code, name, months, price, active, sort) values (p_code, trim(p_name), p_months, p_price, coalesce(p_active, true), coalesce(p_sort, 0))
  on conflict (code) do update set name = excluded.name, months = excluded.months, price = excluded.price, active = excluded.active, sort = excluded.sort;
  insert into audit_log (actor, action, entity, before, after)
  values (auth.uid(), 'plan_upsert', 'plan', v_before, (select to_jsonb(p) from plans p where code = p_code));
end $$;

-- Report: businesses per state now, and subscription money RECORDED as received (activated, by month of activation).
create or replace function public.admin_access_report(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r jsonb;
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 800 then raise exception 'فترة غير صالحة'; end if;
  with st as (
    select s.state from teachers t, business_access_state(t.id, null) s where t.verify = 'verified' and t.user_id is not null
    union all
    select s.state from institutes i, business_access_state(null, i.id) s where i.verify = 'verified' and i.owner_id is not null
  ), paid as (
    select to_char(starts_at at time zone 'Asia/Jerusalem', 'YYYY-MM') m, sum(price) total, count(*) n,
           sum(coalesce(list_price, price) - price) discount
      from subscriptions where status = 'active' and price > 0
       and (starts_at at time zone 'Asia/Jerusalem')::date between p_from and p_to group by 1
  )
  select jsonb_build_object(
    'states', coalesce((select jsonb_object_agg(state, n) from (select state, count(*) n from st group by state) x), '{}'::jsonb),
    'recorded_revenue', coalesce((select sum(total) from paid), 0),
    'by_month', coalesce((select jsonb_agg(jsonb_build_object('month', m, 'total', total, 'count', n, 'discounts', discount) order by m) from paid), '[]'::jsonb),
    'granted_free', (select count(*) from subscriptions where status = 'active' and price = 0 and (starts_at at time zone 'Asia/Jerusalem')::date between p_from and p_to),
    'repeat_trials', (select count(*) from business_trials where repeat_of is not null),
    'notice', 'إيرادات مسجلة يدوياً حسب تأكيد الإدارة، وليست كشفاً بنكياً.'
  ) into r;
  return r;
end $$;

-- ================= reminders =================
-- Daily (existing cron job): 7, 3 and 1 days before a trial or subscription ends, on the day it ends (grace starts),
-- and when grace ends. Only while subscriptions_required is on. Same reminder_log dedupe as before.
create or replace function public.subscription_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0; v_key text; v_days int; v_body text;
begin
  if coalesce(setting('subscriptions_required'), 'false') <> 'true' then return 0; end if;
  for r in
    select t.user_id u, s.*, '/teach#subscription' link from teachers t, business_access_state(t.id, null) s
     where t.user_id is not null and t.verify = 'verified'
    union all
    select i.owner_id, s.*, '/manage#subscription' from institutes i, business_access_state(null, i.id) s
     where i.owner_id is not null and i.verify = 'verified'
  loop
    if r.state not in ('trial','active','grace') or r.ends_at is null then continue; end if;
    v_days := r.days_left;
    if r.state in ('trial','active') and v_days not in (7, 3, 1) then continue; end if;
    if r.state = 'grace' and v_days not in (access_setting_int('grace_days', 7), 1) then continue; end if;
    v_key := format('access:%s:%s:%s:%s', r.u, r.state, to_char(r.ends_at, 'YYYYMMDD'), v_days);
    insert into reminder_log (key) values (v_key) on conflict do nothing;
    if not found then continue; end if;
    v_body := case
      when r.state = 'trial' then format('تجربتك المجانية في Classi تنتهي خلال %s %s. اختر باقة حتى تبقى ظاهراً للزبائن.', v_days, case when v_days = 1 then 'يوم' else 'أيام' end)
      when r.state = 'active' then format('اشتراكك في Classi ينتهي خلال %s %s. جدّده حتى تبقى ظاهراً للزبائن.', v_days, case when v_days = 1 then 'يوم' else 'أيام' end)
      when v_days = 1 then 'غداً تنتهي فترة السماح وتختفي صفحتك عن الزبائن. بياناتك محفوظة وتعود فور التجديد.'
      else format('انتهت فترتك، ولديك %s أيام سماح تبقى فيها ظاهراً. جدّد الاشتراك لتستمر.', v_days) end;
    insert into notifications (user_id, kind, body, link) values (r.u, 'subscription', v_body, r.link);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

revoke all on function public.access_start_trial(), public.my_access_state(), public.admin_business_access(),
  public.admin_extend_trial(uuid, uuid, int, text), public.admin_set_exemption(uuid, uuid, date, text),
  public.admin_discount_request(uuid, int, text), public.admin_upsert_plan(text, text, int, int, boolean, int),
  public.admin_access_report(date, date), public.subscription_reminders() from public, anon, authenticated;
grant execute on function public.my_access_state(), public.admin_business_access(),
  public.admin_extend_trial(uuid, uuid, int, text), public.admin_set_exemption(uuid, uuid, date, text),
  public.admin_discount_request(uuid, int, text), public.admin_upsert_plan(text, text, int, int, boolean, int),
  public.admin_access_report(date, date) to authenticated;
-- owner_has_access and admin_set_setting were re-created: re-state their grants exactly as before.
grant execute on function public.owner_has_access(uuid, uuid) to anon, authenticated;
grant execute on function public.admin_set_setting(text, text) to authenticated;
revoke all on function public.admin_set_setting(text, text) from public, anon;
