-- Rollback of D-08 step A (20261114000000_d08_workers.sql). Run step B's rollback first if B was applied.
-- Removes the worker_* functions and the step marker, and puts back the Auth hook of 20261031000000. No data is deleted.

drop function if exists public.worker_wake_ok(text);
drop function if exists public.worker_claim_push(int);
drop function if exists public.worker_push_keys();
drop function if exists public.worker_drop_push_subscriptions(text[]);
drop function if exists public.worker_log_sms(jsonb);
drop function if exists public.worker_claim_otp();
delete from public.app_secrets where key = 'd08_worker_seen_at';
alter function public.notifications_mark_push() reset search_path;

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
  delete from otp_outbox where created_at < now() - interval '15 minutes';
  insert into otp_outbox (phone, body, email, otp)
  values (v_phone, format('%s هو رمز الدخول إلى Classi. صالح 5 دقائق. لا تشاركه مع أحد.', v_otp),
          case when coalesce(v_type, '') <> 'phone_change' then nullif(event->'user'->>'email', '') end, v_otp);
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
