\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000005','dad@t','{"full_name":"أبو آدم"}'),
 ('40000000-0000-0000-0000-000000000006','stranger@t','{"full_name":"غريب"}');
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
insert into children (id, guardian_id, name) values ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000004','يوسف');
create temp table ids as select (select id from offerings where title='رياضيات بجروت 5 وحدات') priv,
  ((date_trunc('week', now() at time zone 'Asia/Jerusalem')::date + 14) + time '16:00') at time zone 'Asia/Jerusalem' as mon;
grant select on ids to authenticated;
-- mom booked once before (so she is Samer's student), for Yousef
insert into bookings (offering_id, booked_by, child_id, starts_at, minutes, status, mode)
values ((select priv from ids), '40000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000001', (select mon from ids) - interval '7 days', 60, 'confirmed', 'home');
delete from notifications;

\echo '===== 1. Samer closes Monday 18:00-19:00 every week for 4 weeks'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'closed' t, teacher_block((select mon from ids) + interval '2 hours', 60, 'طالب من خارج التطبيق', 4);
select 'my students' t, name, guardian from my_students();
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select 'dad sees the hour busy' t, count(*) from teacher_busy((select id from teachers where name='سامر مصاروة'), (select mon from ids), (select mon from ids) + interval '1 day');
select 'dad books inside closed hour (expect error)' t;
select create_booking((select priv from ids), null, (select mon from ids) + interval '2 hours');
select 'dad cannot read blocks (expect 0)' t, count(*) from teacher_blocks;
reset role;

\echo '===== 2. Samer puts Yousef into Monday 16:00 weekly; a stranger cannot be added'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'weekly add' t, teacher_add_booking((select priv from ids), '40000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000001', (select mon from ids), true);
select 'stranger (expect error)' t;
select teacher_add_booking((select priv from ids), '40000000-0000-0000-0000-000000000006', null, (select mon from ids) + interval '4 hours');
select 'into closed hour (expect error)' t;
select teacher_add_booking((select priv from ids), '40000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000001', (select mon from ids) + interval '2 hours 15 minutes');
reset role;
select 'mom told' t, body from notifications where user_id='40000000-0000-0000-0000-000000000004';

\echo '===== 3. Move one lesson; move the weekly slot from week 3 on'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'move one' t, teacher_move_booking((select id from bookings where series_id is not null order by starts_at limit 1), (select mon from ids) + interval '1 day', 'one', 'عندي اجتماع يوم الاثنين');
select 'move onto closed hour (expect error)' t;
select teacher_move_booking((select id from bookings where series_id is not null order by starts_at offset 1 limit 1), (select mon from ids) + interval '7 days 2 hours');
select 'move following' t, teacher_move_booking((select id from bookings where series_id is not null order by starts_at offset 2 limit 1),
       (select starts_at from bookings where series_id is not null order by starts_at offset 2 limit 1) + interval '2 days 1 hour', 'following');
select 'calendar' t, kind, to_char(starts_at at time zone 'Asia/Jerusalem','Dy DD/MM HH24:MI') at, who, note, changed from my_teacher_calendar(now(), now() + interval '40 days') limit 9;
reset role;
select 'series first_start now (local)' t, to_char(first_start at time zone 'Asia/Jerusalem','Dy HH24:MI') from recurring_series;
select 'mom told' t, body from notifications where user_id='40000000-0000-0000-0000-000000000004' and kind='schedule_changed';

\echo '===== 4. Mom cancels the moved lesson for free even if it is soon'
update bookings set starts_at = now() + interval '3 hours' where id = (select id from bookings where changed_at is not null order by starts_at limit 1);
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select cancel_booking((select id from bookings where changed_at is not null and booked_by = auth.uid() order by starts_at limit 1));
select 'cancelled ok' t;
reset role;

\echo '===== 5. Teacher cancels the weekly slot with a reason; opens the closed hours'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'cancel series' t, teacher_cancel_booking((select id from bookings where series_id is not null and status='confirmed' order by starts_at limit 1), 'series', 'انتهى الفصل');
select 'open all closed' t, teacher_unblock((select id from teacher_blocks order by starts_at limit 1), true);
select 'blocks left' t, count(*) from teacher_blocks;
reset role;
select 'mom told' t, body from notifications where user_id='40000000-0000-0000-0000-000000000004' and kind='booking_cancelled';
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select 'dad cannot move others (expect error)' t;
select teacher_move_booking((select id from bookings limit 1), now() + interval '2 days');
reset role;
