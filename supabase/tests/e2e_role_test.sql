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
  ('e2e00000-0000-4000-8000-000000000001', '972521000001', null, now()),                       -- test account (allowlisted)
  ('e2e00000-0000-4000-8000-000000000002', '972521000002', null, now() - interval '3 days'),   -- allowlisted number, old account
  ('e2e00000-0000-4000-8000-000000000003', '972521000003', 'someone@example.com', now()),      -- allowlisted number, has an e-mail
  ('e2e00000-0000-4000-8000-000000000004', '972521234501', null, now()),                       -- fresh, 0521 range, NOT allowlisted
  ('e2e00000-0000-4000-8000-000000000005', '972541234567', null, now());                       -- other number range
insert into public.teachers (id, user_id, name, town) values ('e2e00000-0000-4000-8000-0000000000a1', 'e2e00000-0000-4000-8000-000000000001', 'معلم اختبار', 'باقة الغربية');
insert into public.offerings (id, type, teacher_id, title, places, price, minutes) values ('e2e00000-0000-4000-8000-0000000000b1', 'private', 'e2e00000-0000-4000-8000-0000000000a1', 'عرض اختبار', '{online}', 100, 60);
insert into public.otp_outbox (phone, body, otp) values ('972521000001', 'x', '123456'), ('972500000003', 'x', '999999'), ('972521234501', 'x', '555555');

create function pg_temp.t(p_test text, p_sql text, p_expect text) returns void language plpgsql as $$
declare v text; e text;
begin
  begin execute p_sql into v; v := 'allowed:' || coalesce(v, 'null');
  exception when others then v := 'refused'; e := sqlerrm;
  end;
  insert into r (test, result) values (p_test, case when (p_expect = 'refused') = (v = 'refused') then 'PASS' else 'FAIL: ' || v || coalesce(' (' || e || ')', '') end);
end $$;
grant execute on function pg_temp.t(text, text, text) to e2e_staging;
create function pg_temp.must(ok boolean) returns text language plpgsql as $$
begin if ok is not true then raise exception 'unexpected value'; end if; return 'ok'; end $$;
grant execute on function pg_temp.must(boolean) to e2e_staging;

set local role e2e_staging;
-- allowed, test account only
select pg_temp.t('read the code of a test number', $q$select e2e.otp('972521000001')$q$, 'allowed');
select pg_temp.t('read the code of a fresh 0521 number that is not allowlisted (refused)', $q$select e2e.otp('972521234501')$q$, 'refused');
select pg_temp.t('find a fresh 0521 account that is not allowlisted (refused)', $q$select e2e.user_id('972521234501')::text$q$, 'refused');
select pg_temp.t('make a fresh 0521 account that is not allowlisted admin (refused)', $q$select e2e.make_admin('e2e00000-0000-4000-8000-000000000004')::text$q$, 'refused');
select pg_temp.t('next number: allowlisted and unused', $q$select pg_temp.must(e2e.next_phone(1) = '972521000004')$q$, 'allowed');
select pg_temp.t('next number again: a different one', $q$select pg_temp.must(e2e.next_phone(1) = '972521000005')$q$, 'allowed');
select pg_temp.t('add a number to the allowlist (refused)', $q$insert into e2e.test_phones values ('972521234501', 1) returning digits$q$, 'refused');
select pg_temp.t('read the allowlist directly (refused)', $q$select count(*)::text from e2e.test_phones$q$, 'refused');
select pg_temp.t('clear reservations (refused)', $q$delete from e2e.reservations returning digits$q$, 'refused');
select pg_temp.t('read the code of a manual test account (refused)', $q$select e2e.otp('972500000003')$q$, 'refused');
select pg_temp.t('read the code of another number range (refused)', $q$select e2e.otp('972541234567')$q$, 'refused');
select pg_temp.t('find the test account', $q$select e2e.user_id('972521000001')::text$q$, 'allowed');
select pg_temp.t('find an old account on an allowlisted number (refused)', $q$select e2e.user_id('972521000002')::text$q$, 'refused');
select pg_temp.t('find an account that has an e-mail (refused)', $q$select e2e.user_id('972521000003')::text$q$, 'refused');
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
-- the role is locked by default, and running the file again locks it again
insert into r (test, result) select 'role is NOLOGIN after setup', case when not rolcanlogin then 'PASS' else 'FAIL: can log in' end from pg_roles where rolname = 'e2e_staging';
insert into r (test, result) select 'role has no special attributes', case when not (rolsuper or rolcreaterole or rolcreatedb or rolreplication or rolbypassrls or rolinherit) then 'PASS' else 'FAIL: attribute set' end from pg_roles where rolname = 'e2e_staging';
insert into r (test, result) select 'no table or column grants', case when (select count(*) from information_schema.role_table_grants where grantee = 'e2e_staging' and table_schema not like 'pg_temp%') + (select count(*) from information_schema.column_privileges where grantee = 'e2e_staging' and table_schema not like 'pg_temp%') = 0 then 'PASS' else 'FAIL: grants found' end;
insert into r (test, result) select 'every e2e function: SECURITY DEFINER where it reads data, search_path empty, owner postgres',
  case when count(*) filter (where not (p.proconfig @> array['search_path=""'] or p.proconfig @> array['search_path=']) or pg_get_userbyid(p.proowner) <> 'postgres') = 0 then 'PASS' else 'FAIL: ' || string_agg(p.proname, ',') filter (where not (p.proconfig @> array['search_path=""'] or p.proconfig @> array['search_path=']) or pg_get_userbyid(p.proowner) <> 'postgres') end
  from pg_proc p where p.pronamespace = 'e2e'::regnamespace;
insert into r (test, result) select 'nobody but e2e_staging may run the helpers (anon, authenticated, service_role, PUBLIC)',
  case when count(*) = 0 then 'PASS' else 'FAIL: ' || string_agg(distinct p.proname, ',') end
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.pronamespace = 'e2e'::regnamespace and a.privilege_type = 'EXECUTE' and a.grantee not in ('e2e_staging'::regrole, p.proowner);
insert into r (test, result) select 'internal checks are callable by nobody but the owner',
  case when count(*) = 0 then 'PASS' else 'FAIL: ' || string_agg(distinct p.proname, ',') end
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.pronamespace = 'e2e'::regnamespace and p.proname like '\_%' and a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner;
select n, test, result from r order by n;
select count(*) filter (where result = 'PASS') || ' passed, ' || count(*) filter (where result <> 'PASS') || ' failed' as e2e_role from r;
rollback;

-- outside the transaction (the file has its own): open the role, run the file again, it must be locked
alter role e2e_staging login;
\o /dev/null
\ir ../staging/e2e_role.sql
\o
select case when not rolcanlogin then 'PASS: running the file again locks a role that was opened' else 'FAIL: still can log in after re-running the file' end as relock from pg_roles where rolname = 'e2e_staging';
