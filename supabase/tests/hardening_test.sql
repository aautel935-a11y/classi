\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000005','dad@t','{"full_name":"أبو سليم"}'),
 ('40000000-0000-0000-0000-000000000007','owner@t','{"full_name":"صاحب المعهد"}');
update institutes set owner_id='40000000-0000-0000-0000-000000000007' where name='معهد المستقبل';
create temp table ids as select (select id from offerings where title='إنجليزي محادثة للإعدادي') crs;
grant select on ids to authenticated;
delete from notifications;

\echo '===== 1. Cancel a course meeting with a make-up meeting'
select 'before' t, count(*) filter (where not cancelled) active, max(seq) last_seq, (select sessions_count from offerings where id=(select crs from ids)) cnt from sessions where offering_id=(select crs from ids);
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000007';
select cancel_session((select id from sessions where offering_id=(select crs from ids) and starts_at > now() order by starts_at limit 1), 'مرض المعلم', true);
reset role; reset request.jwt.claim.sub;
select 'after' t, count(*) filter (where not cancelled) active, max(seq) last_seq, (select sessions_count from offerings where id=(select crs from ids)) cnt,
       (select review_status || coalesce(pending_changes::text,'') from offerings where id=(select crs from ids)) review from sessions where offering_id=(select crs from ids);
select 'new last 7 days after previous' t, (select starts_at from sessions where offering_id=(select crs from ids) order by seq desc limit 1)
  - (select starts_at from sessions where offering_id=(select crs from ids) order by seq desc offset 1 limit 1) gap;

\echo '===== 2. Walk-in, father joins a week later with the same phone; institute links'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000007';
select 'walk-in' t, institute_enroll((select crs from ids), 'سليم', '052-777 1234', 'installments', true) is not null;
select 'can link yet?' t, can_link from owner_bookings((select crs from ids)) where student_name='سليم';
select 'link too early (expect error)' t;
select institute_link_booking((select booking_id from owner_bookings((select crs from ids)) where student_name='سليم'));
reset role; reset request.jwt.claim.sub;
update profiles set phone = clean_phone('0527771234') where id='40000000-0000-0000-0000-000000000005';
select 'owner told' t, body from notifications where user_id='40000000-0000-0000-0000-000000000007' and body like 'انضم%';
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select 'dad sees before link (expect 0)' t, count(*) from bookings where booked_by = auth.uid();
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000007';
select 'can link now' t, can_link from owner_bookings((select crs from ids)) where student_name='سليم';
select institute_link_booking((select booking_id from owner_bookings((select crs from ids)) where student_name='سليم'));
select 'after link' t, offline, can_link, installments_paid from owner_bookings((select crs from ids)) where student_name='سليم';
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select 'dad sees it' t, count(*) from bookings where booked_by = auth.uid();
select 'dad cannot link others (expect error)' t;
select institute_link_booking((select id from bookings where booked_by = auth.uid()));
reset role;

\echo '===== 3. Last seat guard'
update offerings set seats = (select count(*) from bookings where offering_id=(select crs from ids) and status in ('pending','confirmed')) + 1 where id=(select crs from ids);
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000007';
select 'last seat ok' t, institute_enroll((select crs from ids), 'أخير', null, 'cash', false) is not null;
reset role; reset request.jwt.claim.sub;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'student takes a seat when full (expect error)' t;
select create_booking((select crs from ids), null, null);
reset role; reset request.jwt.claim.sub;
