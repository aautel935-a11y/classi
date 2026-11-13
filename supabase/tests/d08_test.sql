-- D-08 regression suite (TM-13, TM-14; TM-06 / TM-12 / TM-21 are app-level: tests/unit/d08.test.mjs, tests/check-worker-key.mjs).
-- Every check prints "PASS: …" or "FAIL: …"; run_all.sh fails on any FAIL. Synthetic accounts only (ids 7000…).
\pset pager off
\pset footer off
set client_min_messages = notice;

-- pg_net is not available locally: a stand-in records the wake-up call.
create schema if not exists net;
create table if not exists net.calls (url text, body jsonb);
create or replace function net.http_post(url text, body jsonb, headers jsonb default null, timeout_milliseconds int default null) returns bigint
language sql as $$ insert into net.calls values (url, body) returning 1::bigint $$;
insert into app_secrets (key, value) values ('dispatch_url', 'https://example.test/api/push/dispatch'), ('dispatch_secret', 'd08-secret'),
  ('vapid_public', 'PUBKEY'), ('vapid_private', 'PRIVATE-KEY-MUST-NOT-LEAK') on conflict (key) do update set value = excluded.value;
insert into auth.users (id, phone, email, email_confirmed_at, raw_user_meta_data) values
 ('70000000-0000-0000-0000-000000000001', '972507000001', 'ok@t', now(), '{"full_name":"حساب مؤكد"}'),
 ('70000000-0000-0000-0000-000000000002', '972507000002', 'no@t', null, '{"full_name":"حساب غير مؤكد"}');
update profiles set phone = '+972507000001', sms_ok = true where id = '70000000-0000-0000-0000-000000000001';
insert into push_subscriptions (user_id, endpoint, p256dh, auth) values ('70000000-0000-0000-0000-000000000001', 'https://push.example/1', 'K', 'A');

\echo '===== TM-13: nothing reachable with the public key hands out deliveries, codes or keys'
select t_is('the old secret-gated anon functions are gone',
  $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname in ('claim_push','claim_otp','log_sms','drop_push_subscriptions')$$, '0');
select t_is('worker_* functions: anon may execute none',
  $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname like 'worker\_%' and has_function_privilege('anon', oid, 'execute')$$, '0');
select t_is('worker_* functions: authenticated may execute none',
  $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname like 'worker\_%' and has_function_privilege('authenticated', oid, 'execute')$$, '0');
select t_is('worker_* functions: service_role may execute all six',
  $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname like 'worker\_%' and has_function_privilege('service_role', oid, 'execute')$$, '6');
select t_is('every worker_* function is SECURITY DEFINER with search_path public, pg_temp',
  $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname like 'worker\_%' and not (prosecdef and proconfig = '{"search_path=public, pg_temp"}')$$, '0');
-- general guard: no function anon or authenticated can execute reads the secrets or the code outbox
select t_is('no anon/authenticated function reads app_secrets or otp_outbox',
  $$select coalesce(string_agg(proname, ',' order by proname), '') from pg_proc where pronamespace = 'public'::regnamespace
     and (prosrc ilike '%app_secrets%' or prosrc ilike '%otp_outbox%')
     and (has_function_privilege('anon', oid, 'execute') or has_function_privilege('authenticated', oid, 'execute'))$$, '');
set role anon;
select t_err('anon: worker_claim_push refused', $$select worker_claim_push(25)$$);
select t_err('anon: worker_push_keys refused', $$select worker_push_keys()$$);
select t_err('anon: worker_claim_otp refused', $$select worker_claim_otp()$$);
select t_err('anon: worker_wake_ok refused', $$select worker_wake_ok('d08-secret')$$);
select t_err('anon: worker_log_sms refused', $$select worker_log_sms('[]')$$);
select t_err('anon: worker_drop_push_subscriptions refused', $$select worker_drop_push_subscriptions(array['https://push.example/1'])$$);
select t_err('anon: app_secrets unreadable', $$select value from app_secrets$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select t_err('authenticated: worker_claim_push refused', $$select worker_claim_push(25)$$);
select t_err('authenticated: worker_claim_otp refused', $$select worker_claim_otp()$$);
reset role; reset request.jwt.claim.sub;

\echo '===== TM-13: the wake-up secret only proves the call came from the database'
set role service_role;
select t_is('empty secret refused', $$select worker_wake_ok('')::text$$, 'false');
select t_is('null secret refused', $$select worker_wake_ok(null)::text$$, 'false');
select t_is('wrong secret refused', $$select worker_wake_ok('guess')::text$$, 'false');
reset role;
select t_is('no marker after refused wake-ups', $$select count(*)::text from app_secrets where key = 'd08_worker_seen_at'$$, '0');
set role service_role;
select t_is('right secret accepted', $$select worker_wake_ok('d08-secret')::text$$, 'true');
reset role;
select t_is('accepted wake-up recorded (step B guard)', $$select count(*)::text from app_secrets where key = 'd08_worker_seen_at' and value::timestamptz > now() - interval '1 minute'$$, '1');

\echo '===== TM-13: deliveries without any key; the private key only to the server'
insert into notifications (user_id, kind, body) values ('70000000-0000-0000-0000-000000000001', 'message', 'رسالة من أم يوسف: موعد الغد 17:00');
set role service_role;
create temp table claimed as select worker_claim_push(25) x;
select t_is('one item claimed', $$select jsonb_array_length(x)::text from claimed$$, '1');
select t_is('the claim carries no key', $$select (x::text like '%PRIVATE-KEY%' or x::text like '%vapid%')::text from claimed$$, 'false');
select t_is('the claim carries the subscription', $$select jsonb_array_length(x->0->'subs')::text from claimed$$, '1');
select t_is('claimed once (again: 0)', $$select jsonb_array_length(worker_claim_push(25))::text$$, '0');
select t_is('keys for the server', $$select (worker_push_keys()->>'vapid_private')$$, 'PRIVATE-KEY-MUST-NOT-LEAK');
select t_is('dead subscription dropped', $$select worker_drop_push_subscriptions(array['https://push.example/1'])::text$$, '1');
select t_is('SMS log written', $$select worker_log_sms('[{"id":"","phone":"0507000001","ok":true,"detail":"test"}]')::text$$, '1');
reset role;

\echo '===== TM-14: a code waits at most 5 minutes, is handed over once, and has no column of its own'
select t_is('otp_outbox has no otp column', $$select count(*)::text from information_schema.columns where table_schema = 'public' and table_name = 'otp_outbox' and column_name = 'otp'$$, '0');
select t_is('otp_outbox: RLS on, no policies', $$select (relrowsecurity and not exists (select 1 from pg_policies where tablename = 'otp_outbox'))::text from pg_class where oid = 'public.otp_outbox'::regclass$$, 'true');
select send_sms_hook('{"user":{"phone":"972507000001","email":"ok@t","email_confirmed_at":"2026-11-01T00:00:00Z"},"sms":{"otp":"482913"}}') is not null queued;
set role anon;
select t_is('anon sees no waiting code', $$select count(*)::text from otp_outbox$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select t_is('the account itself sees no waiting code', $$select count(*)::text from otp_outbox$$, '0');
reset role; reset request.jwt.claim.sub;
set role service_role;
create temp table otp1 as select worker_claim_otp() x;
select t_is('code handed over inside the SMS text', $$select (x->0->>'body' like '482913 %')::text from otp1$$, 'true');
select t_is('confirmed email kept for the fallback', $$select x->0->>'email' from otp1$$, 'ok@t');
select t_is('no separate code field', $$select (x->0 ? 'otp')::text from otp1$$, 'false');
select t_is('handed over once', $$select worker_claim_otp()::text$$, '[]');
reset role;
select t_is('outbox empty after the hand-over', $$select count(*)::text from otp_outbox$$, '0');
-- unconfirmed email: never used for the fallback (in the hook, and again when claimed)
select send_sms_hook('{"user":{"phone":"972507000002","email":"no@t"},"sms":{"otp":"111222"}}') is not null queued;
insert into otp_outbox (phone, body, email) values ('972507000002', '333444 هو رمز الدخول إلى Classi.', 'no@t');  -- as if an older hook had kept it
set role service_role;
select t_is('unconfirmed email never returned', $$select count(*)::text from jsonb_array_elements(worker_claim_otp()) e where e->>'email' is not null$$, '0');
reset role;
-- expiry: a code older than its 5-minute validity is deleted, never handed over
insert into otp_outbox (phone, body, created_at) values ('972507000001', '555666 هو رمز الدخول إلى Classi.', now() - interval '6 minutes');
set role service_role;
select t_is('expired code not handed over', $$select worker_claim_otp()::text$$, '[]');
reset role;
select t_is('expired code deleted', $$select count(*)::text from otp_outbox$$, '0');
insert into otp_outbox (phone, body, created_at) values ('972507000001', '777888 هو رمز الدخول إلى Classi.', now() - interval '6 minutes');
select send_sms_hook('{"user":{"phone":"972507000001"},"sms":{"otp":"999000"}}') is not null queued;
select t_is('a new code also purges expired ones', $$select string_agg(left(body, 6), ',') from otp_outbox$$, '999000');
select t_is('the wake-up call never carries the code', $$select count(*)::text from net.calls where body::text ~ '\d{6}'$$, '0');
