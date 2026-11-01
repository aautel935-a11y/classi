-- Tests for supabase/staging/e2e_role.sql (the least-privilege role of the staging browser tests).
-- Run by run_all.sh on a fresh local database: marks it staging, loads the staging data and the role, then checks
-- what the role can and cannot do (the checks themselves run in one transaction that is rolled back).
\set ON_ERROR_STOP 1
\pset pager off
insert into public.app_secrets (key, value) values ('deploy_env', 'staging'), ('dispatch_url', 'https://classi-staging.invalid/api/push/dispatch')
on conflict (key) do update set value = excluded.value;
\o /dev/null
\ir ../staging/staging_data.sql
\ir ../staging/e2e_role.sql
\o
begin;
create temp table r (n serial, test text, result text);
grant all on r to e2e_staging; grant usage on sequence r_n_seq to e2e_staging;

-- fixtures (as postgres): a fresh test account with a teacher profile and an offer, plus accounts that must stay out of reach
insert into auth.users (id, phone, email, created_at) values
  ('e2e00000-0000-4000-8000-000000000001', '972521234501', null, now()),                       -- test account
  ('e2e00000-0000-4000-8000-000000000002', '972521234599', null, now() - interval '3 days'),   -- old account, test-like number
  ('e2e00000-0000-4000-8000-000000000003', '972521234577', 'someone@example.com', now()),      -- has an e-mail
  ('e2e00000-0000-4000-8000-000000000004', '972541234567', null, now());                       -- other number range
insert into public.teachers (id, user_id, name, town) values ('e2e00000-0000-4000-8000-0000000000a1', 'e2e00000-0000-4000-8000-000000000001', 'معلم اختبار', 'باقة الغربية');
insert into public.offerings (id, type, teacher_id, title, places, price, minutes) values ('e2e00000-0000-4000-8000-0000000000b1', 'private', 'e2e00000-0000-4000-8000-0000000000a1', 'عرض اختبار', '{online}', 100, 60);
insert into public.otp_outbox (phone, body, otp) values ('972521234501', 'x', '123456'), ('972500000003', 'x', '999999');

create function pg_temp.t(p_test text, p_sql text, p_expect text) returns void language plpgsql as $$
declare v text;
begin
  begin execute p_sql into v; v := 'allowed:' || coalesce(v, 'null');
  exception when others then v := 'refused';
  end;
  insert into r (test, result) values (p_test, case when (p_expect = 'refused') = (v = 'refused') then 'PASS' else 'FAIL: ' || v end);
end $$;
grant execute on function pg_temp.t(text, text, text) to e2e_staging;

set local role e2e_staging;
-- allowed, test account only
select pg_temp.t('read the code of a test number', $q$select e2e.otp('972521234501')$q$, 'allowed');
select pg_temp.t('read the code of a manual test account (refused)', $q$select e2e.otp('972500000003')$q$, 'refused');
select pg_temp.t('read the code of another number range (refused)', $q$select e2e.otp('972541234567')$q$, 'refused');
select pg_temp.t('find the test account', $q$select e2e.user_id('972521234501')::text$q$, 'allowed');
select pg_temp.t('find an old account with a test-like number (refused)', $q$select e2e.user_id('972521234599')::text$q$, 'refused');
select pg_temp.t('find an account that has an e-mail (refused)', $q$select e2e.user_id('972521234577')::text$q$, 'refused');
select pg_temp.t('teacher id of the test account', $q$select e2e.teacher_id('e2e00000-0000-4000-8000-000000000001')::text$q$, 'allowed');
select pg_temp.t('verify the test teacher', $q$select e2e.verify_teacher('e2e00000-0000-4000-8000-0000000000a1')::text$q$, 'allowed');
select pg_temp.t('approve the test offer', $q$select e2e.approve_offer('e2e00000-0000-4000-8000-0000000000b1')::text$q$, 'allowed');
select pg_temp.t('bookings of the test offer', $q$select count(*)::text from e2e.offer_bookings('e2e00000-0000-4000-8000-0000000000b1')$q$, 'allowed');
select pg_temp.t('make the test account admin', $q$select e2e.make_admin('e2e00000-0000-4000-8000-000000000001')::text$q$, 'allowed');
-- the same actions on anything else are refused
select pg_temp.t('make an old account admin (refused)', $q$select e2e.make_admin('e2e00000-0000-4000-8000-000000000002')::text$q$, 'refused');
select pg_temp.t('make an account with e-mail admin (refused)', $q$select e2e.make_admin('e2e00000-0000-4000-8000-000000000003')::text$q$, 'refused');
select pg_temp.t('make a manual test account admin (refused)', $q$select e2e.make_admin('00000000-0000-4000-8000-000000000003')::text$q$, 'refused');
select pg_temp.t('verify a teacher with a real account (refused)', $q$select e2e.verify_teacher((select id from public.teachers where name = 'سامر مصاروة'))::text$q$, 'refused');
select pg_temp.t('approve an offer of another teacher (refused)', $q$select e2e.approve_offer((select id from public.offerings where title = 'رياضيات بجروت 5 وحدات'))::text$q$, 'refused');
select pg_temp.t('read bookings of another offer (refused)', $q$select count(*)::text from e2e.offer_bookings((select id from public.offerings where title = 'رياضيات بجروت 5 وحدات'))$q$, 'refused');
select pg_temp.t('unread count of a manual account (refused)', $q$select e2e.unread_count('00000000-0000-4000-8000-000000000001')::text$q$, 'refused');
select pg_temp.t('edit the bio of a teacher with an account (refused)', $q$select e2e.set_demo_bio((select id from public.teachers where name = 'سامر مصاروة'), 'x')::text$q$, 'refused');
select pg_temp.t('edit the bio of a demo listing', $q$select e2e.set_demo_bio(e2e.demo_teacher(), 'نص')::text$q$, 'allowed');
-- no direct access at all
select pg_temp.t('read bookings directly (refused)', $q$select count(*)::text from public.bookings$q$, 'refused');
select pg_temp.t('read messages directly (refused)', $q$select count(*)::text from public.messages$q$, 'refused');
select pg_temp.t('read app_secrets (refused)', $q$select count(*)::text from public.app_secrets$q$, 'refused');
select pg_temp.t('read auth.users (refused)', $q$select count(*)::text from auth.users$q$, 'refused');
select pg_temp.t('read the sign-in outbox directly (refused)', $q$select count(*)::text from public.otp_outbox$q$, 'refused');
select pg_temp.t('update a teacher directly (refused)', $q$update public.teachers set verify = 'verified' returning id::text$q$, 'refused');
select pg_temp.t('call an internal check (refused)', $q$select e2e._test_user('e2e00000-0000-4000-8000-000000000001')::text$q$, 'refused');
select pg_temp.t('call an admin function of the app (refused)', $q$select public.admin_stats()::text$q$, 'refused');
select pg_temp.t('create a table in e2e (refused)', $q$create table e2e.x (a int)$q$, 'refused');
select pg_temp.t('create a table in public (refused)', $q$create table public.x (a int)$q$, 'refused');
select pg_temp.t('create a role (refused)', $q$create role x$q$, 'refused');
select pg_temp.t('become postgres (refused)', $q$set role postgres$q$, 'refused');
reset role;

select n, test, result from r order by n;
select count(*) filter (where result = 'PASS') || ' passed, ' || count(*) filter (where result <> 'PASS') || ' failed' as e2e_role from r;
rollback;
