-- Classi: sign in with phone number + SMS code.
-- Supabase Auth makes the code, checks it, limits attempts and opens the session.
-- Its "Send SMS" hook calls send_sms_hook() below, which queues the text and wakes the site,
-- and the site sends it through 019 (the 019 token stays in Vercel, never in the database).
--
-- Dashboard settings that go with this file (done once):
--   Authentication → Hooks → Send SMS → Postgres → public.send_sms_hook
--   Authentication → Sign In / Providers → Phone → enabled, OTP 6 digits, expiry 300 seconds

create table if not exists public.otp_outbox (
  id         bigserial primary key,
  phone      text not null,
  body       text not null,
  created_at timestamptz not null default now()
);
alter table public.otp_outbox enable row level security;  -- no policies: only the functions below touch it

create or replace function public.send_sms_hook(event jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  -- Sign-in sends to user.phone; linking or changing a number sends to the new one (user.phone_change).
  v_phone text := coalesce(nullif(event->'sms'->>'phone', ''),
                           case when event->'sms'->>'sms_type' = 'phone_change' then nullif(event->'user'->>'phone_change', '') end,
                           nullif(event->'user'->>'phone', ''),
                           nullif(event->'user'->>'phone_change', ''));
  v_otp text := event->'sms'->>'otp'; v_url text; v_secret text;
begin
  if coalesce(v_phone, '') = '' or coalesce(v_otp, '') = '' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'missing phone or code'));
  end if;
  delete from otp_outbox where created_at < now() - interval '15 minutes';
  insert into otp_outbox (phone, body)
  values (v_phone, format('%s هو رمز الدخول إلى Classi. صالح 5 دقائق. لا تشاركه مع أحد.', v_otp));
  select regexp_replace(value, '/api/.*$', '/api/sms/otp') into v_url from app_secrets where key = 'dispatch_url';
  select value into v_secret from app_secrets where key = 'dispatch_secret';
  if v_url is not null and v_secret is not null then
    perform net.http_post(url := v_url, body := jsonb_build_object('secret', v_secret),
                          headers := '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 15000);
  end if;
  return '{}'::jsonb;
exception when others then
  return jsonb_build_object('error', jsonb_build_object('http_code', 500, 'message', 'تعذّر إرسال الرمز، حاول بعد قليل'));
end $$;

-- The site picks up waiting codes (and they are deleted as they are handed over).
create or replace function public.claim_otp(p_secret text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if p_secret is null or p_secret is distinct from (select value from app_secrets where key = 'dispatch_secret') then
    raise exception 'unauthorized';
  end if;
  with picked as (
    delete from otp_outbox where id in (select id from otp_outbox where created_at > now() - interval '10 minutes'
                                         order by id limit 50 for update skip locked)
    returning phone, body
  )
  select coalesce(jsonb_agg(jsonb_build_object('phone', phone, 'body', body)), '[]'::jsonb) into v from picked;
  return v;
end $$;

revoke execute on function public.send_sms_hook, public.claim_otp from anon, authenticated, public;
grant execute on function public.claim_otp to anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.send_sms_hook to supabase_auth_admin;
    grant usage on schema public to supabase_auth_admin;
  end if;
end $$;

-- New accounts made by phone: the verified number is the profile phone (in +972 form).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_role app_role;
begin
  v_role := case when new.raw_user_meta_data->>'role' in ('guardian','student','teacher','institute')
                 then (new.raw_user_meta_data->>'role')::app_role else 'guardian' end;
  insert into profiles (id, full_name, phone, town, roles, active_role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''),
          clean_phone(nullif(new.phone, '')),  -- only a number Supabase verified by SMS, never one typed into the form
          nullif(new.raw_user_meta_data->>'town', ''), array[v_role], v_role)
  on conflict (id) do nothing;
  return new;
end $$;

-- A verified phone change (linking a number to an email account) updates the profile phone too.
create or replace function public.auth_phone_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.phone, '') <> '' and new.phone is distinct from old.phone then
    perform set_config('classi.phone_sync', 'on', true);
    update profiles set phone = clean_phone(new.phone) where id = new.id;
    perform set_config('classi.phone_sync', 'off', true);
  end if;
  return new;
end $$;
drop trigger if exists auth_phone_sync on auth.users;
create trigger auth_phone_sync after update of phone on auth.users
  for each row execute function public.auth_phone_sync();

-- The profile phone is the verified one: users cannot type another number into it through the API.
create or replace function public.profiles_phone_guard() returns trigger
language plpgsql as $$
begin
  if new.phone is distinct from old.phone and auth.uid() is not null and not is_admin()
     and coalesce(current_setting('classi.phone_sync', true), '') <> 'on' then
    new.phone := old.phone;
  end if;
  return new;
end $$;
drop trigger if exists profiles_phone_guard on public.profiles;
create trigger profiles_phone_guard before update of phone on public.profiles
  for each row execute function public.profiles_phone_guard();
