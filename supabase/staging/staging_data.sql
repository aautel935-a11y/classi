-- STAGING ONLY. Synthetic data for classi-staging: the growth-size set used in the performance tests
-- (supabase/tests/perf_data.sql: 20,000 accounts, 600 teachers, 60 institutes, 3,000 offers, 200,000 bookings,
-- 300,000 messages), plus five sign-in accounts for manual testing, one per role.
-- Sign-in: Supabase -> Authentication -> Sign In / Providers -> Phone -> "Test phone numbers and OTPs":
--   972500000001 (teacher), 972500000002 (institute), 972500000003 (parent), 972500000004 (student), 972500000005 (admin)
-- with codes chosen by the owner there. These numbers are reserved for testing and never receive real messages.
-- Refuses: a database not marked staging by scripts/staging/setup.sh (app_secrets deploy_env = 'staging', so never
-- production, however few accounts it has), a database whose dispatcher points at classi.click, a second run, or a
-- database that already holds more than the seed. One transaction: all or nothing.
begin;
do $$ begin
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then
    raise exception 'refusing: this database is not marked staging (run scripts/staging/setup.sh on the staging project first)';
  end if;
  if exists (select 1 from public.app_secrets where key = 'dispatch_url' and value ilike '%classi.click%') then
    raise exception 'refusing: dispatch_url points at the production site';
  end if;
  if exists (select 1 from auth.users where id = '00000000-0000-4000-8000-000000000001') then
    raise exception 'staging data already loaded';
  end if;
  if (select count(*) from auth.users) > 20 then raise exception 'refusing: this database already has accounts'; end if;
end $$;

\ir ../tests/perf_data.sql

-- Five accounts for people testing by hand (phones are the reserved test numbers above).
do $$
declare r record; has_confirm boolean := exists (select 1 from information_schema.columns
  where table_schema = 'auth' and table_name = 'users' and column_name = 'phone_confirmed_at');
begin
  for r in select * from (values ('972500000001', '00000000-0000-4000-8000-000000000001'),   -- teacher 1
                                 ('972500000002', '00000000-0000-4000-8000-000000000601'),   -- institute 1 owner
                                 ('972500000003', '00000000-0000-4000-8000-000000001000'),   -- parent with bookings
                                 ('972500000004', '00000000-0000-4000-8000-000000001001'),   -- student
                                 ('972500000005', '00000000-0000-4000-8000-000000001002')) v(phone, id) loop
    update auth.users set phone = r.phone where id = r.id::uuid;
    if has_confirm then execute 'update auth.users set phone_confirmed_at = now() where id = $1' using r.id::uuid; end if;
  end loop;
end $$;
update profiles set roles = '{student}', active_role = 'student', full_name = 'طالب تجريبي' where id = '00000000-0000-4000-8000-000000001001';
update profiles set roles = '{admin}', active_role = 'guardian', full_name = 'مدير تجريبي' where id = '00000000-0000-4000-8000-000000001002';
update profiles set full_name = 'معلم تجريبي' where id = '00000000-0000-4000-8000-000000000001';
update profiles set full_name = 'صاحب معهد تجريبي' where id = '00000000-0000-4000-8000-000000000601';
update profiles set full_name = 'ولي أمر تجريبي' where id = '00000000-0000-4000-8000-000000001000';
-- a child for the parent account, and confirmed availability for the teacher (so booking works by hand)
insert into children (guardian_id, name, grade) values ('00000000-0000-4000-8000-000000001000', 'يوسف التجريبي', '8');
insert into availability (teacher_id, weekday, start_time, end_time)
select '00000000-0000-4000-8000-000000100001', d, '15:00', '21:00' from generate_series(0, 6) d where d <> 5
on conflict do nothing;
update teachers set hours_confirmed_at = now() where id = '00000000-0000-4000-8000-000000100001';
select 'accounts' as what, count(*) from auth.users
union all select 'test sign-in accounts', count(*) from auth.users where phone like '9725000000%'
union all select 'offers', count(*) from offerings
union all select 'bookings', count(*) from bookings
union all select 'messages', count(*) from messages;
commit;
