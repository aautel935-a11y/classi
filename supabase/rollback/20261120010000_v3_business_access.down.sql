-- Rollback of 20261120010000_v3_business_access.sql. Puts back owner_has_access and subscription_reminders of
-- 20261026020000_launch.sql and admin_set_setting of 20261031020000_phase3_performance_settings.sql, then removes the
-- trial/exemption tables, triggers and functions. Data lost: trial rows, exemptions, discount reasons/list prices,
-- and the trial_days / grace_days / launch_at settings. Subscriptions themselves are kept.
begin;
drop trigger if exists teachers_start_trial on public.teachers;
drop trigger if exists institutes_start_trial on public.institutes;
drop function if exists public.access_start_trial();
drop function if exists public.my_access_state();
drop function if exists public.admin_business_access();
drop function if exists public.admin_extend_trial(uuid, uuid, int, text);
drop function if exists public.admin_set_exemption(uuid, uuid, date, text);
drop function if exists public.admin_discount_request(uuid, int, text);
drop function if exists public.admin_upsert_plan(text, text, int, int, boolean, int);
drop function if exists public.admin_access_report(date, date);
create or replace function public.owner_has_access(p_teacher uuid, p_institute uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(setting('subscriptions_required'), 'false') <> 'true'
      or (p_teacher is not null and (select user_id is null from teachers where id = p_teacher))
      or (p_institute is not null and (select owner_id is null from institutes where id = p_institute))
      or coalesce(paid_until(p_teacher, p_institute) > now(), false)
$$;

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

drop function if exists public.business_access_state(uuid, uuid);
drop function if exists public.access_trial_end(uuid, uuid);
drop function if exists public.access_exempt_until(uuid, uuid);
drop function if exists public.access_phone_hash(uuid);
drop function if exists public.access_launch_at();
drop function if exists public.access_setting_int(text, int);
drop table if exists public.business_exemptions;
drop table if exists public.business_trials;
alter table public.subscriptions drop column if exists list_price;
alter table public.subscriptions drop column if exists discount_reason;
delete from public.app_settings where key in ('trial_days','grace_days','launch_at');
grant execute on function public.owner_has_access(uuid, uuid) to anon, authenticated;
grant execute on function public.admin_set_setting(text, text) to authenticated;
commit;
