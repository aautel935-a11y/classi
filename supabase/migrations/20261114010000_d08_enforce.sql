-- D-08 step B (enforce): run ONLY after the app code that uses the worker_* functions is deployed and has handled at
-- least one wake-up (app_secrets d08_worker_seen_at; the guarded staging/production files check it).
-- TM-13: the anon-callable functions behind the dispatch_secret are removed. Nothing reachable with the public key hands
--   out notifications, phones, emails, sign-in codes or the VAPID private key any more, even if the secret leaks.
-- TM-14: the separate plain-text otp column is removed; the code exists only inside the SMS text of a row that is
--   deleted when it is sent and never waits more than 5 minutes.
-- Before B the old app code breaks (it calls claim_push / claim_otp); after B the new code works unchanged.
-- Rollback: supabase/rollback/20261114010000_d08_enforce.down.sql (puts the four functions and the column back).

drop function if exists public.claim_push(text, int);
drop function if exists public.claim_otp(text);
drop function if exists public.log_sms(text, jsonb);
drop function if exists public.drop_push_subscriptions(text, text[]);

create or replace function public.send_sms_hook(event jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_type text := event->'sms'->>'sms_type';
  v_phone text := coalesce(nullif(event->'sms'->>'phone', ''),
                           case when v_type = 'phone_change' then nullif(event->'user'->>'phone_change', '') end,
                           nullif(event->'user'->>'phone', ''),
                           nullif(event->'user'->>'phone_change', ''));
  v_digits text := regexp_replace(coalesce(v_phone, ''), '\D', '', 'g');
  v_otp text := event->'sms'->>'otp'; v_url text; v_secret text;
begin
  if v_digits = '' or coalesce(v_otp, '') = '' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'missing phone or code'));
  end if;
  if v_digits !~ '^9725\d{8}$' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'Classi يعمل بأرقام الجوال الإسرائيلية فقط (05x)'));
  end if;
  delete from otp_requests where created_at < now() - interval '2 days';
  if (select count(*) from otp_requests where phone = v_digits and created_at > now() - interval '1 hour')
       >= coalesce(nullif(setting('otp_per_hour'), '')::int, 5)
     or (select count(*) from otp_requests where phone = v_digits and created_at > now() - interval '1 day')
       >= coalesce(nullif(setting('otp_per_day'), '')::int, 15) then
    return jsonb_build_object('error', jsonb_build_object('http_code', 429, 'message', 'طلبت رموزاً كثيرة لهذا الرقم. حاول بعد ساعة.'));
  end if;
  insert into otp_requests (phone) values (v_digits);
  delete from otp_outbox where created_at < now() - interval '5 minutes';
  insert into otp_outbox (phone, body, email)
  values (v_phone, format('%s هو رمز الدخول إلى Classi. صالح 5 دقائق. لا تشاركه مع أحد.', v_otp),
          case when coalesce(v_type, '') <> 'phone_change' and nullif(event->'user'->>'email_confirmed_at', '') is not null
               then nullif(event->'user'->>'email', '') end);
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

alter table public.otp_outbox drop column if exists otp;
