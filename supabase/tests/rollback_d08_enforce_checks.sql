-- After the rollback of D-08 step B (20261114010000_d08_enforce): the four secret-gated anon functions and the otp column
-- are back exactly as before (the step-A app code and the old app code both work), and step A's worker path still works.
-- PASS:/FAIL: lines.
\pset pager off
\pset footer off
set client_min_messages = notice;
create schema if not exists net;
create table if not exists net.calls (url text, body jsonb);
create or replace function net.http_post(url text, body jsonb, headers jsonb default null, timeout_milliseconds int default null) returns bigint
language sql as $$ insert into net.calls values (url, body) returning 1::bigint $$;
insert into app_secrets (key, value) values ('dispatch_secret', 'rb-secret'), ('vapid_private', 'PRIV') on conflict (key) do update set value = excluded.value;
select t_is('the four functions are back', $$select string_agg(proname, ',' order by proname) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('claim_push','claim_otp','log_sms','drop_push_subscriptions')$$, 'claim_otp,claim_push,drop_push_subscriptions,log_sms');
select t_is('…executable by anon again (old app code)', $$select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and proname in ('claim_push','claim_otp','log_sms','drop_push_subscriptions') and has_function_privilege('anon', oid, 'execute')$$, '4');
select t_is('the otp column is back', $$select count(*)::text from information_schema.columns where table_name = 'otp_outbox' and column_name = 'otp'$$, '1');
select send_sms_hook('{"user":{"phone":"972507100001"},"sms":{"otp":"246810"}}') is not null queued;
set role anon;
select t_err('old path: wrong secret refused', $$select claim_otp('nope')$$);
select t_is('old path: the code is claimed with the secret (step-A hook fills the column)', $$select claim_otp('rb-secret') -> 0 ->> 'otp'$$, '246810');
reset role;
set role service_role;
select t_is('step A worker path still works', $$select worker_wake_ok('rb-secret')::text$$, 'true');
select t_is('worker claim still carries no key', $$select (worker_claim_push(5)::text like '%PRIV%')::text$$, 'false');
reset role;
