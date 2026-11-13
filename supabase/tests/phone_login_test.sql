\pset pager off
\pset footer off
-- pg_net is not available locally: a stand-in records the wake-up call.
create schema if not exists net;
create table if not exists net.calls (url text, body jsonb);
create or replace function net.http_post(url text, body jsonb, headers jsonb default null, timeout_milliseconds int default null) returns bigint
language sql as $$ insert into net.calls values (url, body) returning 1::bigint $$;
insert into app_secrets (key, value) values ('dispatch_url', 'https://classi-nine.vercel.app/api/push/dispatch'), ('dispatch_secret', 's3cret')
  on conflict (key) do update set value = excluded.value;

\echo '===== 1. Supabase asks for a code to be sent'
select 'hook result' t, send_sms_hook('{"user":{"phone":"972501112233"},"sms":{"otp":"482913"}}');
select 'queued' t, phone, body from otp_outbox;
select 'site woken at' t, url, body->>'secret' = 's3cret' secret_ok from net.calls;
select 'phone change goes to the new number' t, send_sms_hook('{"user":{"phone":"","phone_change":"972524445555"},"sms":{"otp":"111222","sms_type":"phone_change"}}');
select 'queued for' t, phone from otp_outbox order by id desc limit 1;
delete from otp_outbox where phone = '972524445555';
select 'bad event' t, send_sms_hook('{"user":{"phone":""},"sms":{"otp":"1"}}') -> 'error' ->> 'http_code';

\echo '===== 2. The site collects it once (D-08: service role only; the secret only proves the wake-up)'
select 'wrong secret: not woken (expect f)' t, worker_wake_ok('nope');
select 'right secret: woken (expect t)' t, worker_wake_ok('s3cret');
set role service_role;
select 'claim' t, worker_claim_otp();
select 'again (expect [])' t, worker_claim_otp();
reset role;
select 'outbox empty' t, count(*) from otp_outbox;

\echo '===== 3. New account by phone: role, name, verified number'
insert into auth.users (id, phone, raw_user_meta_data) values
 ('50000000-0000-0000-0000-000000000001', '972501112233', '{"full_name":"ليلى","role":"teacher","phone":"0529999999"}');
select 'profile' t, full_name, phone, active_role from profiles where id = '50000000-0000-0000-0000-000000000001';

\echo '===== 4. Users cannot type another number into their profile'
set role authenticated; set request.jwt.claim.sub='50000000-0000-0000-0000-000000000001';
update profiles set phone = '+972507777777', full_name = 'ليلى خ' where id = auth.uid();
reset role; reset request.jwt.claim.sub;
select 'after typing' t, full_name, phone from profiles where id = '50000000-0000-0000-0000-000000000001';

\echo '===== 5. Email account links a number (verified by Supabase): profile follows'
insert into auth.users (id, email, raw_user_meta_data) values ('50000000-0000-0000-0000-000000000002', 'old@t', '{"full_name":"قديم","phone":"0521234567"}');
select 'email signup ignores typed phone' t, phone from profiles where id = '50000000-0000-0000-0000-000000000002';
update auth.users set phone = '972523334444' where id = '50000000-0000-0000-0000-000000000002';
select 'after verified change' t, phone from profiles where id = '50000000-0000-0000-0000-000000000002';

\echo '===== 6. Email fallback only to a CONFIRMED account email (D-08 / TM-14); phone-change codes never (SEC-10)'
insert into auth.users (id, phone, email, email_confirmed_at) values ('50000000-0000-0000-0000-000000000003', '972529998877', 'majd@t', now());
select send_sms_hook('{"user":{"phone":"972529998877","email":"majd@t","email_confirmed_at":"2026-11-01T00:00:00Z"},"sms":{"otp":"654321"}}');
set role service_role;
select 'confirmed email kept (expect majd@t)' t, worker_claim_otp() -> 0 ->> 'email' email, worker_claim_otp() = '[]'::jsonb emptied;
reset role;
select send_sms_hook('{"user":{"phone":"972529998878","email":"unconfirmed@t"},"sms":{"otp":"654323"}}');
set role service_role;
select 'unconfirmed email: no fallback (expect empty)' t, worker_claim_otp() -> 0 ->> 'email' email;
reset role;
select send_sms_hook('{"user":{"phone":"","phone_change":"972529998866","email":"majd@t","email_confirmed_at":"2026-11-01T00:00:00Z"},"sms":{"otp":"654322","sms_type":"phone_change"}}');
set role service_role;
select 'phone change: no email (expect empty)' t, worker_claim_otp() -> 0 ->> 'email' email;
reset role;
