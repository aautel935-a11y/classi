-- D-08 step A (additive; the current app keeps working unchanged): server-only worker functions for the dispatch routes.
-- TM-13: today the routes /api/push/dispatch and /api/sms/otp call claim_push / claim_otp / log_sms / drop_push_subscriptions
--   with the PUBLIC (anon) key and the shared dispatch_secret. Whoever learns that secret can call them from anywhere and
--   receives every pending notification with phones and emails, the VAPID private key, and every waiting sign-in code.
--   Now: worker_* functions are executable by service_role ONLY (the server's secret key, never in a browser and never
--   granted to anon or authenticated). The dispatch_secret only proves that the database woke the route.
--   claim_push no longer has to hand out the VAPID private key: worker_push_keys() gives it to the server only.
-- TM-14: a sign-in code waits in otp_outbox for at most 5 minutes (the code's own validity, was 15), it is deleted when it
--   is handed over (as before), and the email fallback goes only to an email address the user has CONFIRMED.
-- Step B (20261114010000_d08_enforce.sql) removes the old anon-callable functions and the separate otp column, after the
-- app code that uses the worker functions is deployed and has proved itself (d08_worker_seen_at).
-- Rollback: supabase/rollback/20261114000000_d08_workers.down.sql. Safe on a live database: new functions, one function
-- body (send_sms_hook), no data change.

------------------------------------------------------------------------------------------------------------
-- 1. The wake-up check: the route proves the call came from the database (pg_net) before doing any work.
--    Also records that the new server path is live (step B refuses to run until it has been seen).
------------------------------------------------------------------------------------------------------------
create or replace function public.worker_wake_ok(p_secret text) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ok boolean;
begin
  v_ok := coalesce(p_secret, '') <> '' and p_secret = (select value from app_secrets where key = 'dispatch_secret');
  if v_ok then
    insert into app_secrets (key, value) values ('d08_worker_seen_at', now()::text)
    on conflict (key) do update set value = excluded.value;
  end if;
  return v_ok;
end $$;

------------------------------------------------------------------------------------------------------------
-- 2. Push, email and SMS deliveries: the same items as claim_push, without any key.
------------------------------------------------------------------------------------------------------------
create or replace function public.worker_claim_push(p_limit int default 25)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_items jsonb;
begin
  with picked as (
    update notifications n set pushed_at = now()
     where n.id in (select id from notifications where want_push and pushed_at is null
                     and created_at > now() - interval '2 hours'
                     order by created_at limit least(greatest(coalesce(p_limit, 25), 1), 500) for update skip locked)
    returning n.id, n.user_id, n.kind, n.body, n.link
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', pk.id, 'kind', pk.kind, 'body', pk.body, 'link', pk.link,
           'email', case when pk.kind = 'reminder' and pr.email_reminders then u.email end,
           -- nested CASE: the quota is only spent when an SMS would really be sent
           'phone', case when pk.kind = any(sms_kinds()) and pr.sms_ok and pr.phone is not null and is_active_user(pr.id)
                         then case when sms_allow(pr.id) then pr.phone end end,
           'name', pr.full_name,
           'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth)))
                               from push_subscriptions s where s.user_id = pk.user_id), '[]'::jsonb))), '[]'::jsonb)
    into v_items
    from picked pk join profiles pr on pr.id = pk.user_id left join auth.users u on u.id = pk.user_id;
  update notifications set pushed_at = now() where want_push and pushed_at is null and created_at <= now() - interval '2 hours';
  return v_items;
end $$;

-- The push key pair, for the server only (it signs Web Push requests).
create or replace function public.worker_push_keys() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'vapid_public', (select value from app_secrets where key = 'vapid_public'),
    'vapid_private', (select value from app_secrets where key = 'vapid_private'),
    'subject', coalesce((select value from app_secrets where key = 'vapid_subject'), 'mailto:admin@classi.app'))
$$;

create or replace function public.worker_drop_push_subscriptions(p_endpoints text[]) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  delete from push_subscriptions where endpoint = any(coalesce(p_endpoints, '{}'));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.worker_log_sms(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  insert into sms_log (notification_id, phone, ok, detail)
  select nullif(r->>'id', '')::uuid, r->>'phone', coalesce((r->>'ok')::boolean, false), left(r->>'detail', 300)
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

------------------------------------------------------------------------------------------------------------
-- 3. Sign-in codes (TM-14): handed over once (the row is deleted), only within their 5-minute validity, and the
--    email fallback only to an email the account has confirmed. The code itself travels inside the SMS text only.
------------------------------------------------------------------------------------------------------------
create or replace function public.worker_claim_otp() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  delete from otp_outbox where created_at <= now() - interval '5 minutes';
  with picked as (
    delete from otp_outbox where id in (select id from otp_outbox order by id limit 50 for update skip locked)
    returning phone, body, email
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'phone', p.phone, 'body', p.body,
           'email', case when p.email is not null and exists (select 1 from auth.users u
                                                             where lower(u.email) = lower(p.email) and u.email_confirmed_at is not null)
                         then p.email end)), '[]'::jsonb)
    into v from picked p;
  return v;
end $$;

-- The Auth hook: same checks and limits as before (20261031000000), a 5-minute outbox, and an email kept for the
-- fallback only when the account's email is confirmed. Still fills the otp column for the app code of step A.
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
  insert into otp_outbox (phone, body, email, otp)
  values (v_phone, format('%s هو رمز الدخول إلى Classi. صالح 5 دقائق. لا تشاركه مع أحد.', v_otp),
          -- a phone-change code is never emailed (the email belongs to the requesting account, not to the number's
          -- owner), and the fallback goes only to a confirmed email
          case when coalesce(v_type, '') <> 'phone_change' and nullif(event->'user'->>'email_confirmed_at', '') is not null
               then nullif(event->'user'->>'email', '') end,
          v_otp);
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

------------------------------------------------------------------------------------------------------------
-- 4. Privileges: worker_* for service_role only (default privileges would also give them to anon/authenticated).
------------------------------------------------------------------------------------------------------------
revoke execute on function public.worker_wake_ok(text), public.worker_claim_push(int), public.worker_push_keys(),
  public.worker_drop_push_subscriptions(text[]), public.worker_log_sms(jsonb), public.worker_claim_otp()
  from public, anon, authenticated;
grant execute on function public.worker_wake_ok(text), public.worker_claim_push(int), public.worker_push_keys(),
  public.worker_drop_push_subscriptions(text[]), public.worker_log_sms(jsonb), public.worker_claim_otp()
  to service_role;
-- the hook keeps its own grant (to supabase_auth_admin, 20261026050000_phone_login.sql); re-creating it keeps grants

-- Supabase advisor "search_path mutable": pin it on the notifications trigger (not SECURITY DEFINER, plain names).
-- search_offers keeps NO search_path on purpose (20261101000000: a SET clause stops the planner from inlining it, which
-- once made the search take 3 s); it is SECURITY INVOKER and every name in it is schema-qualified, so it is safe as is.
alter function public.notifications_mark_push() set search_path = public, pg_temp;
