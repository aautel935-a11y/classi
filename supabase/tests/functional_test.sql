-- Phase 2 functional regression suite (BUG-02/04/05/13/26 in CLASSI_BUG_REPORT.md). PASS:/FAIL: assertions.
-- Synthetic accounts only (ids 9000…).
\pset pager off
\pset footer off
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
 ('90000000-0000-0000-0000-00000000000b','samer@t','{"full_name":"سامر مصاروة"}'),
 ('90000000-0000-0000-0000-00000000000c','owner@t','{"full_name":"صاحب المعهد"}'),
 ('90000000-0000-0000-0000-00000000000d','mom@t','{"full_name":"أم يوسف"}');
update teachers set user_id='90000000-0000-0000-0000-00000000000b' where name='سامر مصاروة';
update institutes set owner_id='90000000-0000-0000-0000-00000000000c' where name='معهد المستقبل';
insert into children (guardian_id, name) values ('90000000-0000-0000-0000-00000000000d', 'يوسف'), ('90000000-0000-0000-0000-00000000000d', 'سلمى');
create temp table ids as select
  (select id from teachers where name='سامر مصاروة') samer,
  (select id from offerings where title='رياضيات بجروت 5 وحدات') priv,
  (select id from offerings where title='مجموعة تقوية رياضيات، صف عاشر') grp,
  (select id from offerings where title='إنجليزي محادثة للإعدادي') crs,
  (select id from children where name='يوسف') kid,
  (select id from children where name='سلمى') kid2;
grant select on ids to anon, authenticated;

\echo '===== BUG-04 saving hours is all-or-nothing'
set role authenticated; set request.jwt.claim.sub='90000000-0000-0000-0000-00000000000b';
select t_is('hours before', $$select count(*)::text from availability where teacher_id = (select samer from ids)$$, '5');
select t_err('bad hours (end before start) are refused', $$select replace_availability('[{"weekday":1,"start":"10:00","end":"09:00"}]', 0)$$);
select t_err('bad time format is refused', $$select replace_availability('[{"weekday":1,"start":"9:00","end":"25:00"}]', 0)$$);
select t_err('overlapping ranges on one day are refused', $$select replace_availability('[{"weekday":1,"start":"10:00","end":"14:00"},{"weekday":1,"start":"13:00","end":"16:00"}]', 0)$$);
select t_is('after refused saves, every hour is still there', $$select count(*)::text from availability where teacher_id = (select samer from ids)$$, '5');
select t_is('a good save replaces the hours and reports how many ranges', $$select replace_availability('[{"weekday":0,"start":"15:00","end":"20:00"},{"weekday":6,"start":"09:00","end":"12:00"},{"weekday":2,"start":"08:00","end":"10:00"},{"weekday":2,"start":"16:00","end":"21:00"}]', 10)::text$$, '4');
select t_is('saved exactly', $$select string_agg(weekday || ' ' || to_char(start_time,'HH24:MI') || '-' || to_char(end_time,'HH24:MI'), ', ' order by weekday, start_time) from availability where teacher_id = (select samer from ids)$$,
  '0 15:00-20:00, 2 08:00-10:00, 2 16:00-21:00, 6 09:00-12:00');
select t_is('break saved with the hours', $$select buffer_minutes::text from teachers where id = (select samer from ids)$$, '10');
select t_ok('clearing all hours is allowed (the teacher pauses)', $$select replace_availability('[]', 0)$$);
select t_is('no hours now', $$select count(*)::text from availability where teacher_id = (select samer from ids)$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub='90000000-0000-0000-0000-00000000000d';
select t_err('a parent cannot save a teacher''s hours', $$select replace_availability('[{"weekday":0,"start":"15:00","end":"20:00"}]', 0)$$);
reset role;

\echo '===== BUG-13 "set your hours" is done only when the teacher saved them'
insert into auth.users (id, email, raw_user_meta_data) values ('90000000-0000-0000-0000-0000000000a1','new@t','{"full_name":"معلم جديد"}');
set role authenticated; set request.jwt.claim.sub='90000000-0000-0000-0000-0000000000a1';
select t_ok('new teacher creates a profile', $$insert into teachers (user_id, name, town) values (auth.uid(), 'معلم جديد', 'باقة الغربية')$$);
select t_is('default hours exist but are not confirmed', $$select (select count(*) from availability where teacher_id = my_teacher_id())::text || ':' || (hours_confirmed_at is null)::text from teachers where user_id = auth.uid()$$, '5:true');
select t_ok('teacher saves hours', $$select replace_availability('[{"weekday":0,"start":"16:00","end":"19:00"}]', 0)$$);
select t_is('now confirmed', $$select (hours_confirmed_at is not null)::text from teachers where user_id = auth.uid()$$, 'true');
reset role;

\echo '===== BUG-02 same-day private lessons, at least 2 hours ahead'
set role authenticated; set request.jwt.claim.sub='90000000-0000-0000-0000-00000000000b';
-- open every day 00:00-23:59 so the test does not depend on the time it runs
select replace_availability((select jsonb_agg(jsonb_build_object('weekday', d, 'start', '00:00', 'end', '23:59')) from generate_series(0, 6) d), 0);
reset role;
set role authenticated; set request.jwt.claim.sub='90000000-0000-0000-0000-00000000000d';
select t_err('a lesson 30 minutes from now is too soon', $$select create_booking((select priv from ids), null, date_trunc('minute', now()) + interval '30 minutes', null, 'bit', false, 'online')$$);
select case when ((now() + interval '3 hours') at time zone 'Asia/Jerusalem')::date = (now() at time zone 'Asia/Jerusalem')::date
               and ((now() + interval '4 hours') at time zone 'Asia/Jerusalem')::date = (now() at time zone 'Asia/Jerusalem')::date
  then t_ok('a lesson later today (3 hours ahead) can be booked', $$select create_booking((select priv from ids), null, date_trunc('minute', now()) + interval '3 hours', null, 'bit', false, 'online')$$)
  else t_ok('same-day check skipped (less than 4 hours left today)', $$select 1$$) end;
reset role;

\echo '===== BUG-05 removing a child never moves their bookings to the parent'
set role authenticated; set request.jwt.claim.sub='90000000-0000-0000-0000-00000000000d';
select t_ok('book a group seat for يوسف', $$select create_booking((select grp from ids), (select kid from ids), null, (select id from sessions where offering_id=(select grp from ids) and starts_at > now() order by starts_at limit 1), 'cash')$$);
select t_err('removing يوسف while he has an upcoming lesson is refused', $$delete from children where id = (select kid from ids)$$);
select t_is('the booking still belongs to يوسف', $$select count(*)::text from bookings where child_id = (select kid from ids) and status = 'confirmed'$$, '1');
select t_ok('removing سلمى (no bookings) works', $$delete from children where id = (select kid2 from ids)$$);
select t_ok('cancel يوسف''s lesson', $$select cancel_booking((select id from bookings where child_id = (select kid from ids) and status = 'confirmed'))$$);
select t_ok('now يوسف can be removed', $$delete from children where id = (select kid from ids)$$);
reset role;

\echo '===== BUG-26 one attendance record: the teacher''s report and the institute''s register agree'
insert into bookings (offering_id, booked_by, minutes, status, pay_method)
  values ((select crs from ids), '90000000-0000-0000-0000-00000000000d', 90, 'confirmed', 'cash');
update sessions set starts_at = now() - interval '1 day' where id = (select id from sessions where offering_id = (select crs from ids) order by seq limit 1);
set role authenticated; set request.jwt.claim.sub='90000000-0000-0000-0000-00000000000c';
select t_ok('institute marks the student absent', $$insert into attendance (session_id, booking_id, present)
   values ((select id from sessions where offering_id = (select crs from ids) order by seq limit 1), (select id from bookings where offering_id = (select crs from ids) and booked_by = '90000000-0000-0000-0000-00000000000d'), false)$$);
select t_ok('a lesson report for that meeting', $$select write_session_reports((select id from sessions where offering_id = (select crs from ids) order by seq limit 1), 'الدرس', null,
   jsonb_build_array(jsonb_build_object('booking_id', (select id from bookings where offering_id = (select crs from ids) and booked_by = '90000000-0000-0000-0000-00000000000d'), 'present', true)))$$);
select t_is('the register follows the report', $$select present::text from attendance where booking_id = (select id from bookings where offering_id = (select crs from ids) and booked_by = '90000000-0000-0000-0000-00000000000d')$$, 'true');
select t_ok('institute corrects the register to absent', $$update attendance set present = false where booking_id = (select id from bookings where offering_id = (select crs from ids) and booked_by = '90000000-0000-0000-0000-00000000000d')$$);
select t_is('the report follows the register', $$select present::text from lesson_reports where booking_id = (select id from bookings where offering_id = (select crs from ids) and booked_by = '90000000-0000-0000-0000-00000000000d')$$, 'false');
reset role;
