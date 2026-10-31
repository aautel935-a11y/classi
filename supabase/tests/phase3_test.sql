-- Phase 3: admin-editable limits, and the faster owner_bookings / seats_overview return the same rows as before.
\pset pager off
\pset footer off
set client_min_messages = notice;
insert into auth.users (id, email, raw_user_meta_data) values
 ('b0000000-0000-0000-0000-000000000001','admin@t','{"full_name":"مدير"}'),
 ('b0000000-0000-0000-0000-000000000002','owner@t','{"full_name":"صاحب المعهد"}'),
 ('b0000000-0000-0000-0000-000000000003','samer@t','{"full_name":"سامر"}'),
 ('b0000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم"}');
update profiles set roles = '{admin}' where id = 'b0000000-0000-0000-0000-000000000001';
update institutes set owner_id = 'b0000000-0000-0000-0000-000000000002' where name = 'مركز النخبة للتعليم';
update teachers set user_id = 'b0000000-0000-0000-0000-000000000003' where name = 'سامر مصاروة';
insert into bookings (offering_id, booked_by, minutes, status, pay_method)
select id, 'b0000000-0000-0000-0000-000000000004', 90, 'confirmed', 'cash' from offerings where type = 'course';

\echo '===== admin-editable limits'
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000001';
select t_ok('admin sets the booking notice to 3 hours', $$select admin_set_setting('min_lead_minutes', '180')$$);
select t_is('stored', $$select value from app_settings where key = 'min_lead_minutes'$$, '180');
select t_err('out of range is refused', $$select admin_set_setting('min_lead_minutes', '5000')$$);
select t_err('not a number is refused', $$select admin_set_setting('sms_daily_cap', 'كثير')$$);
select t_err('unknown keys are refused (rollback switches are not admin settings)', $$select admin_set_setting('rule_teacher_hours', 'off')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000004';
select t_err('a parent cannot change limits', $$select admin_set_setting('min_lead_minutes', '0')$$);
reset role;

\echo '===== owner_bookings: same rows as the original definition (is_offering_staff on every booking)'
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000002';
select t_is('institute owner', $$select (select count(*) from owner_bookings())::text || '=' || (select count(*) from bookings b where is_offering_staff(b.offering_id))::text$$,
  (select (select count(*) from bookings b join offerings o on o.id = b.offering_id join institutes i on i.id = o.institute_id where i.name = 'مركز النخبة للتعليم') || '=' || (select count(*) from bookings b join offerings o on o.id = b.offering_id join institutes i on i.id = o.institute_id where i.name = 'مركز النخبة للتعليم')));
reset role;
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000003';
select t_is('course teacher sees the courses he teaches', $$select ((select count(*) from owner_bookings()) = (select count(*) from bookings b where is_offering_staff(b.offering_id)))::text$$, 'true');
select t_is('p_from limits history', $$select count(*)::text from owner_bookings(null, now() + interval '100 years')$$, '0');
reset role;

\echo '===== seats_overview with and without a list'
select t_is('one offer only', $$select count(distinct offering_id)::text from seats_overview(array[(select id from offerings where type = 'course' order by id limit 1)])$$, '1');
select t_is('whole platform unchanged', $$select ((select count(*) from seats_overview()) = (select count(*) from (select 1 from bookings b join offerings o on o.id = b.offering_id where o.type in ('group','course') and b.status in ('pending','confirmed') group by b.offering_id, b.session_id) x))::text$$, 'true');
set role anon;
select t_ok('visitors can still read seat counts', $$select count(*) from seats_overview()$$);
reset role;

\echo '===== publishing an offer returns its id (the app inserts with .select("id"); RLS checks the new row)'
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000003';
select t_ok('teacher publishes a private offer and reads it back in the same statement',
  $$insert into offerings (type, teacher_id, title, price, minutes, places) values ('private', my_teacher_id(), 'عرض جديد للاختبار', 100, 60, '{online}') returning id$$);
reset role;
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000002';
select t_ok('institute owner creates a course and reads it back in the same statement',
  $$insert into offerings (type, institute_id, title, price, minutes, places, seats) select 'course', id, 'دورة جديدة للاختبار', 300, 90, '{center}', 20 from institutes where owner_id = auth.uid() limit 1 returning id$$);
reset role;
set role authenticated; set request.jwt.claim.sub = 'b0000000-0000-0000-0000-000000000004';
select t_err('a parent still cannot create an offer for a teacher',
  $$insert into offerings (type, teacher_id, title, price, minutes, places) select 'private', id, 'انتحال', 1, 60, '{online}' from teachers limit 1 returning id$$);
select t_is('a parent does not see unpublished offers', $$select count(*)::text from offerings where title in ('عرض جديد للاختبار','دورة جديدة للاختبار')$$, '0');
reset role;
