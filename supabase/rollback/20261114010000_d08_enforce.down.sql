-- Rollback of D-08 step B (20261114010000_d08_enforce.sql): the four secret-gated anon functions, the otp column,
-- and the step-A Auth hook come back exactly as they were. Run before rolling back step A. No data is deleted.

alter table public.otp_outbox add column if not exists otp text;

create or replace function public.claim_push(p_secret text, p_limit int default 200)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_items jsonb;
begin
  if p_secret is null or p_secret is distinct from (select value from app_secrets where key = 'dispatch_secret') then
    raise exception 'unauthorized';
  end if;
  with picked as (
    update notifications n set pushed_at = now()
     where n.id in (select id from notifications where want_push and pushed_at is null
                     and created_at > now() - interval '2 hours'
                     order by created_at limit least(greatest(p_limit, 1), 500) for update skip locked)
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
  return jsonb_build_object(
    'vapid_public', (select value from app_secrets where key = 'vapid_public'),
    'vapid_private', (select value from app_secrets where key = 'vapid_private'),
    'subject', coalesce((select value from app_secrets where key = 'vapid_subject'), 'mailto:admin@classi.app'),
    'items', v_items);
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

create or replace function public.log_sms(p_secret text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_secret is null or p_secret is distinct from (select value from app_secrets where key = 'dispatch_secret') then
    raise exception 'unauthorized';
  end if;
  insert into sms_log (notification_id, phone, ok, detail)
  select nullif(r->>'id', '')::uuid, r->>'phone', coalesce((r->>'ok')::boolean, false), left(r->>'detail', 300)
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.drop_push_subscriptions(p_secret text, p_endpoints text[]) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_secret is null or p_secret is distinct from (select value from app_secrets where key = 'dispatch_secret') then
    raise exception 'unauthorized';
  end if;
  delete from push_subscriptions where endpoint = any(p_endpoints);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

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

revoke execute on function public.claim_push(text, int), public.claim_otp(text), public.log_sms(text, jsonb),
  public.drop_push_subscriptions(text, text[]) from public;
grant execute on function public.claim_push(text, int), public.claim_otp(text), public.log_sms(text, jsonb),
  public.drop_push_subscriptions(text, text[]) to anon, authenticated;
