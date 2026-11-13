-- After the rollback of D-08 steps B then A: the database is as before D-08 (20261031000000's Auth hook, the four
-- secret-gated anon functions, no worker_* functions, no step marker). PASS:/FAIL: lines.
\pset pager off
\pset footer off
set client_min_messages = notice;
create schema if not exists net;
create table if not exists net.calls (url text, body jsonb);
create or replace function net.http_post(url text, body jsonb, headers jsonb default null, timeout_milliseconds int default null) returns bigint
language sql as $$ insert into net.calls values (url, body) returning 1::bigint $$;
insert into app_secrets (key, value) values ('dispatch_secret', 'rb-secret') on conflict (key) do update set value = excluded.value;
select t_is('no worker_* function left', $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname like 'worker\_%'$$, '0');
select t_is('no step marker left', $$select count(*)::text from app_secrets where key = 'd08_worker_seen_at'$$, '0');
select t_is('the four functions are there for the old app code', $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname in ('claim_push','claim_otp','log_sms','drop_push_subscriptions') and has_function_privilege('anon', oid, 'execute')$$, '4');
select send_sms_hook('{"user":{"phone":"972507100002","email":"x@t"},"sms":{"otp":"135790"}}') is not null queued;
select t_is('pre-D-08 hook: the account email is kept as before', $$select email from otp_outbox where phone = '972507100002'$$, 'x@t');
set role anon;
select t_is('pre-D-08 path works', $$select claim_otp('rb-secret') -> 0 ->> 'otp'$$, '135790');
reset role;
