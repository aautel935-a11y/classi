-- STAGING ONLY. Small synthetic data for classi-staging, on top of the demo seed (supabase/seed.sql: invented teachers,
-- institutes, offers and meetings). Adds one account per role and a little real activity made through the app's own
-- functions as those users (bookings, an acceptance, a cancellation, a conversation, notifications), so every
-- trigger and rule runs exactly as in the app. No real person's data. No bulk load (the hosted project does not
-- allow switching triggers off, and the owner asked for a small set).
-- Sign-in: Supabase -> Authentication -> Sign In / Providers -> Phone -> "Test phone numbers and OTPs":
--   972500000001 teacher (سامر مصاروة), 972500000002 institute (مركز النخبة للتعليم), 972500000003 parent,
--   972500000004 student, 972500000005 admin. Codes are chosen by the owner there; these numbers never get real SMS.
-- Refuses: a database not marked staging by scripts/staging/setup.sh (app_secrets deploy_env = 'staging', so never
-- production, however few accounts it has), a database whose dispatcher points at classi.click, a second run, or a
-- database that already holds accounts. One transaction: all or nothing.
\set ON_ERROR_STOP 1
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
  if (select count(*) from auth.users) > 0 then raise exception 'refusing: this database already has accounts'; end if;
  if not exists (select 1 from public.teachers where name = 'سامر مصاروة')
     or not exists (select 1 from public.institutes where name = 'مركز النخبة للتعليم') then
    raise exception 'the demo seed (supabase/seed.sql) is missing';
  end if;
end $$;

-- 1. Five accounts (the sign-up trigger creates their profiles), with the reserved test phone numbers.
insert into auth.users (id, email, phone, raw_user_meta_data) values
 ('00000000-0000-4000-8000-000000000001', 'teacher@staging.test',   '972500000001', '{"full_name":"معلم تجريبي"}'),
 ('00000000-0000-4000-8000-000000000002', 'institute@staging.test', '972500000002', '{"full_name":"صاحب معهد تجريبي"}'),
 ('00000000-0000-4000-8000-000000000003', 'parent@staging.test',    '972500000003', '{"full_name":"ولي أمر تجريبي"}'),
 ('00000000-0000-4000-8000-000000000004', 'student@staging.test',   '972500000004', '{"full_name":"طالب تجريبي"}'),
 ('00000000-0000-4000-8000-000000000005', 'admin@staging.test',     '972500000005', '{"full_name":"مدير تجريبي"}');
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'phone_confirmed_at') then
    execute $q$update auth.users set phone_confirmed_at = now() where id::text like '00000000-0000-4000-8000-00000000000_'$q$;
  end if;
end $$;
\ir staging_auth_fix.sql
update profiles set full_name = 'معلم تجريبي',      roles = '{teacher}',         active_role = 'teacher'   where id = '00000000-0000-4000-8000-000000000001';
update profiles set full_name = 'صاحب معهد تجريبي', roles = '{institute}',       active_role = 'institute' where id = '00000000-0000-4000-8000-000000000002';
update profiles set full_name = 'ولي أمر تجريبي',   roles = '{guardian}',        active_role = 'guardian'  where id = '00000000-0000-4000-8000-000000000003';
update profiles set full_name = 'طالب تجريبي',      roles = '{student}',         active_role = 'student'   where id = '00000000-0000-4000-8000-000000000004';
update profiles set full_name = 'مدير تجريبي',      roles = '{guardian,admin}',  active_role = 'guardian'  where id = '00000000-0000-4000-8000-000000000005';
update teachers   set user_id  = '00000000-0000-4000-8000-000000000001' where name = 'سامر مصاروة';
update institutes set owner_id = '00000000-0000-4000-8000-000000000002' where name = 'مركز النخبة للتعليم';

-- 2. Activity, made as the users themselves (RLS and every booking rule apply).
create temp table staging_ids as select
  (select id from offerings where title = 'رياضيات بجروت 5 وحدات') as private_offer,
  (select id from offerings where title like 'مجموعة تقوية رياضيات%' limit 1) as group_offer,
  (select id from offerings where title = 'دورة بجروت رياضيات 5 وحدات') as course_offer,
  (select id from teachers where name = 'سامر مصاروة') as samer,
  ((date_trunc('week', now()) + interval '14 days 16 hours')::timestamp at time zone 'Asia/Jerusalem') as slot1,
  ((date_trunc('week', now()) + interval '15 days 17 hours')::timestamp at time zone 'Asia/Jerusalem') as slot2;
grant select on staging_ids to authenticated;

\o /dev/null
-- parent: a child, two private lessons, a course seat, a message to the teacher
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000003';
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000003","role":"authenticated"}';
insert into children (guardian_id, name, grade) values ('00000000-0000-4000-8000-000000000003', 'يوسف التجريبي', 'صف 12');
select create_booking((select private_offer from staging_ids), (select id from children limit 1), (select slot1 from staging_ids), null, 'bit');
select create_booking((select private_offer from staging_ids), (select id from children limit 1), (select slot2 from staging_ids), null, 'cash');
select create_booking((select course_offer from staging_ids), (select id from children limit 1), null, null, 'installments');
select start_conversation((select samer from staging_ids));
insert into messages (conversation_id, body) values ((select id from conversations limit 1), 'مرحباً أستاذ، هل الحصة في البيت أم عبر الإنترنت؟ (رسالة تجريبية)');
reset role;

-- student: a seat in the teacher's group
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000004';
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000004","role":"authenticated"}';
select create_booking((select group_offer from staging_ids), null, null,
  (select s.id from sessions s where s.offering_id = (select group_offer from staging_ids) and s.starts_at > now() order by s.seq limit 1));
reset role;

-- teacher: accepts the first lesson, replies to the parent
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}';
-- (only if it still waits: the demo seed confirms some offers instantly)
select respond_booking(id, true) from bookings where offering_id = (select private_offer from staging_ids) and starts_at = (select slot1 from staging_ids) and status = 'pending';
insert into messages (conversation_id, body) values ((select id from conversations limit 1), 'أهلاً، عبر الإنترنت أو في البيت، كما يناسبكم. (رسالة تجريبية)');
reset role;

-- parent: cancels the second lesson (the teacher is notified)
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000003';
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000003","role":"authenticated"}';
select cancel_booking((select id from bookings where offering_id = (select private_offer from staging_ids) and starts_at = (select slot2 from staging_ids)));
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claims;

\o
-- 3. What was made (counts only).
select 'accounts' item, count(*)::text n from auth.users
union all select 'teachers / institutes / offers', (select count(*) from teachers) || ' / ' || (select count(*) from institutes) || ' / ' || (select count(*) from offerings)
union all select 'bookings (status)', string_agg(status::text || ' ' || c, ', ') from (select status, count(*) c from bookings group by status) b
union all select 'messages', count(*)::text from messages
union all select 'notifications', count(*)::text from notifications;
commit;
