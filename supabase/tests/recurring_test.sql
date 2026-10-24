\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000003','rana@t','{"full_name":"رنا"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000005','dad@t','{"full_name":"أبو آدم"}');
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
update teachers set user_id='40000000-0000-0000-0000-000000000003' where name='رنا أبو حسين';
-- a Sunday 17:00 two weeks out (avoids Samer's Tuesday group)
create temp table t0 as select ((date_trunc('week', now() at time zone 'Asia/Jerusalem')::date + 14) + time '16:00') at time zone 'Asia/Jerusalem' as sun; -- a Monday 16:00
grant select on t0 to authenticated;

\echo '===== SETTINGS: Samer turns on instant confirm + weekly + 15 min break; Rana stays manual + weekly'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
update offerings set auto_confirm=true, allow_weekly=true where title='رياضيات بجروت 5 وحدات';
update teachers set buffer_minutes=15 where user_id=auth.uid();
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
update offerings set allow_weekly=true where title in ('إنجليزي محادثة وبجروت','مجموعة أونلاين، تحضير الشفوي');
reset role;

\echo '===== 1. Instant single booking'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'single' t, (select status from bookings where id = x.id) from (select create_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), null, (select sun from t0) - interval '7 days') id) x;
select 'parent told instantly' t, body from notifications where kind='booking_answer';
reset role;

\echo '===== 2. Instant weekly booking, 8 weeks'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'weekly result' t, create_weekly_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), null, (select sun from t0)) - 'series_id' res;
select 'occurrences (local time)' t, to_char(starts_at at time zone 'Asia/Jerusalem','Dy DD/MM HH24:MI') at, status from bookings where series_id is not null order by starts_at limit 3;
reset role;

\echo '===== 3. Break: another parent tries 17:30 and 18:10 on that Sunday (lesson 17:00-18:00, break 15)'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select 'at 18:10 (expect error: inside break)' t;
select create_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), null, (select sun from t0) + interval '70 minutes');
select 'at 18:15 ok' t, create_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), null, (select sun from t0) + interval '75 minutes') is not null ok;
select 'same time 3 weeks later (expect error: weekly series holds it)' t;
select create_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), null, (select sun from t0) + interval '21 days');
reset role;

\echo '===== 4. Weekly respects an existing one-off: dad books week 4 first, then mom starts a series the week before'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select create_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), null, (select sun from t0) + interval '3 hours' + interval '28 days') is not null;
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'series skips the taken week' t, create_weekly_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), null, (select sun from t0) + interval '3 hours') -> 'skipped' skipped;
reset role;

\echo '===== 5. Manual teacher: weekly request waits, one approval confirms all'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'manual weekly' t, create_weekly_booking((select id from offerings where title='إنجليزي محادثة وبجروت'), null, (select sun from t0)) ->> 'status' status;
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
select 'Rana request' t, body from notifications where kind='booking_request';
select respond_booking((select booking_id from owner_bookings() where status='pending' and series_id is not null limit 1), true);
select 'after approve' t, status, count(*) from bookings b join offerings o on o.id=b.offering_id where o.title='إنجليزي محادثة وبجروت' group by status;
reset role;

\echo '===== 6. Group weekly: seat in every upcoming meeting'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select 'group weekly' t, create_weekly_booking((select id from offerings where title='مجموعة أونلاين، تحضير الشفوي'), null, null,
  (select s.id from sessions s join offerings o on o.id=s.offering_id where o.title='مجموعة أونلاين، تحضير الشفوي' and s.starts_at > now() order by s.starts_at limit 1)) ->> 'created' created;
select 'weekly not allowed (expect error)' t;
select create_weekly_booking((select id from offerings where title='فيزياء ميكانيكا وكهرباء'), null, (select sun from t0));
reset role;

\echo '===== 7. Cancel whole series'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'cancelled lessons' t, cancel_series((select id from recurring_series where offering_id=(select id from offerings where title='إنجليزي محادثة وبجروت')));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
select 'Rana told' t, body from notifications where kind='booking_cancelled';
select 'stranger cancels mom series (expect error)' t;
select cancel_series((select id from recurring_series r where r.offering_id=(select id from offerings where title='رياضيات بجروت 5 وحدات') limit 1));
reset role;

\echo '===== 8. Extension job is idempotent'
select 'extend #1' t, extend_recurring();
select 'extend #2' t, extend_recurring();
\echo '===== 9. DST: 17:00 stays 17:00 across the clock change'
select 'dst' t, to_char(series_start('2026-10-18 17:00 Asia/Jerusalem'::timestamptz, 0) at time zone 'Asia/Jerusalem','DD/MM HH24:MI') a,
  to_char(series_start('2026-10-18 17:00 Asia/Jerusalem'::timestamptz, 2) at time zone 'Asia/Jerusalem','DD/MM HH24:MI') b;
