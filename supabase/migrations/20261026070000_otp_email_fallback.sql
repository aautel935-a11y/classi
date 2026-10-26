-- Classi: if 019 cannot deliver a sign-in code, the site emails the same code to the account's email (when it has one).
alter table public.otp_outbox add column if not exists email text;
alter table public.otp_outbox add column if not exists otp text;

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
  insert into otp_outbox (phone, body, email, otp)
  values (v_phone, format('%s هو رمز الدخول إلى Classi. صالح 5 دقائق. لا تشاركه مع أحد.', v_otp),
          nullif(event->'user'->>'email', ''), v_otp);
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
    returning phone, body, email, otp
  )
  select coalesce(jsonb_agg(jsonb_build_object('phone', phone, 'body', body, 'email', email, 'otp', otp)), '[]'::jsonb) into v from picked;
  return v;
end $$;
revoke execute on function public.send_sms_hook, public.claim_otp from anon, authenticated, public;
grant execute on function public.claim_otp to anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.send_sms_hook to supabase_auth_admin;
  end if;
end $$;
