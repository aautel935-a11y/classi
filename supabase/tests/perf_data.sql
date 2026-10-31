-- Synthetic data at launch-plus-growth size, for performance measurements only (never on a real project).
-- 20,000 accounts, 600 teachers, 60 institutes, 3,000 offers, ~21,600 meetings, 200,000 bookings,
-- 20,000 conversations with 300,000 messages, 100,000 notifications. Deterministic (fixed seed).
-- Ids: account n = 00000000-0000-4000-8000-<n, 12 digits>. Teacher n uses account n (1..600),
-- institute n is owned by account 600+n (1..60), families are accounts 661..20000.
\set ON_ERROR_STOP 1
select setseed(0.42);
set session_replication_role = replica;   -- bulk load without triggers (synthetic data only)

create or replace function pg_temp.uid(n int) returns uuid language sql immutable as
$$ select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;

insert into auth.users (id, email, raw_user_meta_data)
select pg_temp.uid(g), 'u' || g || '@perf.test', '{}'::jsonb from generate_series(1, 20000) g;
insert into profiles (id, full_name, roles, active_role, town)
select pg_temp.uid(g), 'حساب ' || g,
       case when g <= 600 then '{teacher}'::app_role[] when g <= 660 then '{institute}'::app_role[] else '{guardian}'::app_role[] end,
       case when g <= 600 then 'teacher'::app_role when g <= 660 then 'institute'::app_role else 'guardian'::app_role end,
       (array['باقة الغربية','جت','كفر قرع','عرعرة','أم الفحم'])[1 + g % 5]
  from generate_series(1, 20000) g
on conflict (id) do nothing;

insert into teachers (id, user_id, name, town, subject_id, bio, years, verify, rating, reviews_count)
select pg_temp.uid(100000 + g), pg_temp.uid(g), 'معلم ' || g, (array['باقة الغربية','جت','كفر قرع','عرعرة','أم الفحم'])[1 + g % 5],
       (select id from subjects order by id offset (g % (select count(*) from subjects)) limit 1),
       'نبذة', 1 + g % 20, case when g % 50 = 0 then 'pending'::verify_status else 'verified'::verify_status end, round((3 + random() * 2)::numeric, 1), (random() * 80)::int
  from generate_series(1, 600) g;
insert into institutes (id, owner_id, name, town, verify)
select pg_temp.uid(200000 + g), pg_temp.uid(600 + g), 'معهد ' || g, (array['باقة الغربية','جت','كفر قرع','عرعرة','أم الفحم'])[1 + g % 5],
       case when g % 20 = 0 then 'pending'::verify_status else 'verified'::verify_status end
  from generate_series(1, 60) g;

-- 2,400 teacher offers (per teacher: 2 private, 1 group, 1 recorded) + 600 courses (10 per institute)
insert into offerings (id, type, teacher_id, title, subject_id, places, price, seats, minutes, active, review_status, created_at)
select pg_temp.uid(300000 + (t - 1) * 4 + k), (array['private','private','group','recorded']::offering_type[])[k], pg_temp.uid(100000 + t),
       (array['رياضيات','فيزياء','لغة إنجليزية','كيمياء','عربي'])[1 + (t + k) % 5] || ' ' || t || '-' || k,
       (select id from subjects order by id offset ((t + k) % (select count(*) from subjects)) limit 1),
       case when k = 4 then '{online}'::place_kind[] else '{home,online}'::place_kind[] end,
       80 + (t % 10) * 10, case when k = 3 then 8 end, case when k = 4 then 0 else 60 end, not (t % 55 = 0 and k = 3),
       case when t % 40 = 0 and k = 1 then 'pending' else 'approved' end,
       now() - (t * interval '1 hour')
  from generate_series(1, 600) t, generate_series(1, 4) k;
insert into offerings (id, type, institute_id, course_teacher_id, title, subject_id, places, price, seats, minutes, active, review_status, created_at)
select pg_temp.uid(310000 + (i - 1) * 10 + k), 'course', pg_temp.uid(200000 + i), pg_temp.uid(100000 + 1 + ((i * 10 + k) % 600)),
       'دورة ' || i || '-' || k, (select id from subjects order by id offset ((i + k) % (select count(*) from subjects)) limit 1),
       '{center}', 600, 25, 90, true, 'approved', now() - ((i * 10 + k) * interval '1 hour')
  from generate_series(1, 60) i, generate_series(1, 10) k;

-- a few offers hidden by moderation, a few suspended teacher accounts (visibility must not change)
update offerings set moderation_hidden = true where id in (select pg_temp.uid(300000 + (t - 1) * 4 + 2) from generate_series(45, 600, 45) t);
update profiles set status = 'suspended', suspended_until = now() + interval '3 days' where id in (select pg_temp.uid(g) from generate_series(70, 600, 70) g);

-- meetings: 16 per group (weekly, from 8 weeks ago), 20 per course
insert into sessions (offering_id, seq, starts_at, minutes)
select o.id, s, date_trunc('day', now()) - interval '56 days' + (s * interval '7 days') + interval '17 hours', o.minutes
  from offerings o, generate_series(1, 16) s where o.type = 'group' and o.id::text like '00000000-0000-4000-8000-%';
insert into sessions (offering_id, seq, starts_at, minutes)
select o.id, s, date_trunc('day', now()) - interval '70 days' + (s * interval '7 days') + interval '18 hours', o.minutes
  from offerings o, generate_series(1, 20) s where o.type = 'course' and o.id::text like '00000000-0000-4000-8000-%';

insert into children (guardian_id, name)
select pg_temp.uid(661 + (g % 19340)), 'طفل ' || g from generate_series(1, 10000) g;

-- 200,000 bookings: 150,000 private lessons over a year (most in the past), 30,000 group seats, 20,000 course seats
insert into bookings (offering_id, booked_by, starts_at, minutes, status, pay_method, pay_status, price, created_at)
select pg_temp.uid(300000 + ((g % 600) * 4) + 1 + (g % 2)), pg_temp.uid(661 + (g * 7919) % 19340),
       date_trunc('hour', now()) - interval '335 days' + ((g % 8760) * interval '1 hour') + ((g / 8760) * interval '1 minute'),
       60, (array['confirmed','confirmed','confirmed','cancelled','pending']::booking_status[])[1 + g % 5], 'cash',
       (array['paid','paid','unpaid']::text[])[1 + g % 3], 100,
       now() - interval '340 days' + ((g % 8760) * interval '1 hour')
  from generate_series(1, 150000) g;
insert into bookings (offering_id, session_id, booked_by, minutes, status, pay_method, pay_status, price)
select s.offering_id, s.id, pg_temp.uid((661 + (g::bigint * 104729) % 19340)::int), 90, (array['confirmed','confirmed','cancelled']::booking_status[])[1 + g % 3], 'bit', 'paid', 50
  from generate_series(1, 30000) g
  join lateral (select id, offering_id from sessions where offering_id = pg_temp.uid(300000 + (g % 600) * 4 + 3) order by seq offset (g % 16) limit 1) s on true;
insert into bookings (offering_id, booked_by, child_id, minutes, status, pay_method, pay_status, price)
select pg_temp.uid(310000 + (g % 600) + 1), pg_temp.uid((661 + (g::bigint * 15485863) % 19340)::int), null, 90,
       (array['confirmed','confirmed','confirmed','pending','cancelled']::booking_status[])[1 + g % 5], 'bit',
       (array['paid','reported','unpaid']::text[])[1 + g % 3], 600
  from generate_series(1, 20000) g;

-- conversations: each family talks to a few teachers; 300,000 messages
insert into conversations (user_id, teacher_id, last_message_at)
select distinct on (u, t) pg_temp.uid(661 + u), pg_temp.uid(100000 + 1 + t), now() - (g * interval '7 minutes')
  from (select g, (g * 31) % 19340 as u, (g * 17) % 600 as t from generate_series(1, 20000) g) x
on conflict do nothing;
create temp table conv_list as select row_number() over (order by c.id) - 1 as n, c.id, c.user_id, t.user_id as teacher_user
  from conversations c join teachers t on t.id = c.teacher_id;
create index on conv_list (n);
insert into messages (conversation_id, sender_id, body, created_at, read_at)
select c.id, case when g % 2 = 0 then c.user_id else c.teacher_user end,
       'رسالة ' || g, now() - (g * interval '1 minute'), case when g % 9 = 0 then null else now() end
  from generate_series(1, 300000) g join conv_list c on c.n = g % (select count(*) from conv_list);
insert into waitlist (offering_id, user_id, status)
select pg_temp.uid(300000 + (g % 600) * 4 + 3), pg_temp.uid(661 + (g * 13) % 19340), 'waiting' from generate_series(1, 3000) g
on conflict do nothing;
insert into lesson_packages (offering_id, user_id, size, remaining, price, pay_method, pay_status, status)
select pg_temp.uid(300000 + (g % 600) * 4 + 1), pg_temp.uid(661 + (g * 11) % 19340), 5, 3, 450, 'bit',
       (array['paid','unpaid','reported']::text[])[1 + g % 3], 'active'
  from generate_series(1, 3000) g;
insert into notifications (user_id, kind, body, read_at, created_at)
select pg_temp.uid(1 + (g % 20000)), 'booking', 'إشعار ' || g, case when g % 4 = 0 then null else now() end, now() - (g * interval '2 minutes')
  from generate_series(1, 100000) g;

set session_replication_role = origin;
analyze;
select 'offerings' t, count(*) from offerings union all select 'sessions', count(*) from sessions
union all select 'bookings', count(*) from bookings union all select 'messages', count(*) from messages
union all select 'conversations', count(*) from conversations union all select 'profiles', count(*) from profiles;
