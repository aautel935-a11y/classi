-- Performance measurement (CLASSI_PERFORMANCE.md): synthetic volume, then EXPLAIN ANALYZE of the hot queries.
-- Run on a throw-away local database only:  DB=ct_perf sh supabase/tests/run.sh perf_check
\pset pager off
\pset footer off
set session_replication_role = replica;   -- bulk insert without triggers (synthetic data only)
insert into auth.users (id, email, raw_user_meta_data) values
 ('a0000000-0000-0000-0000-000000000001','t@perf','{"full_name":"معلم"}'), ('a0000000-0000-0000-0000-000000000002','p@perf','{"full_name":"ولي"}');
insert into profiles (id, full_name, roles, active_role) values
 ('a0000000-0000-0000-0000-000000000001','معلم','{teacher}','teacher'), ('a0000000-0000-0000-0000-000000000002','ولي','{guardian}','guardian') on conflict do nothing;
update teachers set user_id='a0000000-0000-0000-0000-000000000001' where name='سامر مصاروة';
-- 50,000 bookings spread over every offer, 100,000 messages in 2,000 conversations
insert into bookings (offering_id, booked_by, starts_at, minutes, status, pay_method)
select o.id, 'a0000000-0000-0000-0000-000000000002', now() - interval '200 days' + (g * interval '7 minutes'), 60,
       (array['confirmed','confirmed','cancelled','pending']::booking_status[])[1 + g % 4], 'cash'
  from generate_series(1, 50000) g join lateral (select id from offerings order by id offset (g % (select count(*) from offerings)) limit 1) o on true;
insert into conversations (user_id, teacher_id)
select 'a0000000-0000-0000-0000-000000000002', t.id from teachers t on conflict do nothing;
insert into messages (conversation_id, sender_id, body, created_at, read_at)
select c.id, 'a0000000-0000-0000-0000-000000000002', 'm', now() - (g * interval '1 minute'), case when g % 10 = 0 then null else now() end
  from generate_series(1, 100000) g join lateral (select id from conversations order by id offset (g % (select count(*) from conversations)) limit 1) c on true;
set session_replication_role = origin;
analyze;

\echo '=== Q1 reminders window (bookings by starts_at)'
explain (analyze, costs off, timing off, summary on) select id from bookings where status = 'confirmed' and starts_at > now() + interval '2 hours' and starts_at <= now() + interval '4 hours';
\echo '=== Q2 seats of one group meeting (bookings by session_id)'
explain (analyze, costs off, timing off, summary on) select count(*) from bookings where session_id = (select id from sessions limit 1);
\echo '=== Q3 meetings of one offer (sessions by offering_id, starts_at)'
explain (analyze, costs off, timing off, summary on) select id from sessions where offering_id = (select id from offerings where type='group' limit 1) and starts_at > now() order by starts_at;
\echo '=== Q4 teacher_busy (two weeks)'
explain (analyze, costs off, timing off, summary on) select * from teacher_busy((select id from teachers where name='سامر مصاروة'), now(), now() + interval '14 days');
\echo '=== Q5 header counts for the teacher (unread messages)'
set role authenticated; set request.jwt.claim.sub = 'a0000000-0000-0000-0000-000000000001';
explain (analyze, costs off, timing off, summary on) select * from my_header_counts();
\echo '=== Q6 owner_bookings for the teacher dashboard'
explain (analyze, costs off, timing off, summary on) select count(*) from owner_bookings();
\echo '=== Q7 seats_overview (whole platform)'
explain (analyze, costs off, timing off, summary on) select count(*) from seats_overview();
reset role;
