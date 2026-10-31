-- Phase 4: the new search and seat functions return what the old code computed; dashboards unchanged; grants.
\pset pager off
\pset footer off
set client_min_messages = notice;
insert into auth.users (id, email, raw_user_meta_data) values
 ('c0000000-0000-0000-0000-000000000002','owner@t','{"full_name":"صاحب المعهد"}'),
 ('c0000000-0000-0000-0000-000000000003','samer@t','{"full_name":"سامر"}'),
 ('c0000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم"}');
update institutes set owner_id = 'c0000000-0000-0000-0000-000000000002' where name = 'مركز النخبة للتعليم';
update teachers set user_id = 'c0000000-0000-0000-0000-000000000003' where name = 'سامر مصاروة';
insert into bookings (offering_id, booked_by, minutes, status, pay_method)
select id, 'c0000000-0000-0000-0000-000000000004', 90, 'confirmed', 'cash' from offerings where type = 'course';
-- an old open request (a course enrolment without a date, made long ago) must stay on the dashboard
insert into bookings (offering_id, booked_by, minutes, status, pay_method, created_at)
select id, 'c0000000-0000-0000-0000-000000000004', 90, 'pending', 'cash', now() - interval '90 days' from offerings
 where institute_id = (select id from institutes where name = 'مركز النخبة للتعليم') and type = 'course' limit 1;

\echo '===== search_offers (visitor)'
set role anon;
select t_is('no filters: every active offer with a visible owner, oldest first',
  $$select (select string_agg(id::text, ',' order by n) from search_offers(null, null, null, null, null, null, 100, 0) with ordinality r(id, total, n))
          = (select string_agg(o.id::text, ',' order by o.created_at, o.id) from offerings o where o.active
               and (exists (select 1 from teachers t where t.id = o.teacher_id) or exists (select 1 from institutes i where i.id = o.institute_id)))$$::text, 'true');
select t_is('total is the full count, not the page size', $$select (max(total) = (select count(*) from search_offers(null,null,null,null,null,null,100,0)))::text from search_offers(null, null, null, null, null, null, 2, 0)$$, 'true');
select t_is('page 2 continues page 1', $$select ((select array_agg(id order by n) from search_offers(null,null,null,null,null,null,2,0) with ordinality r(id,total,n))
          || (select array_agg(id order by n) from search_offers(null,null,null,null,null,null,2,2) with ordinality r(id,total,n)))
          = (select array_agg(id order by n) from search_offers(null,null,null,null,null,null,4,0) with ordinality r(id,total,n))$$::text, 'true');
select t_is('type filter', $$select bool_and(o.type = 'course')::text from search_offers('course', null, null, null, null, null, 100, 0) s join offerings o on o.id = s.id$$, 'true');
select t_is('text is case-sensitive and literal (% is not a wildcard)', $$select count(*)::text from search_offers(null, null, null, null, null, '%', 100, 0)$$, '0');
select t_is('page size is capped at 100', $$select (count(*) <= 100)::text from search_offers(null, null, null, null, null, null, 100000, 0)$$, 'true');
select t_is('hidden offers stay hidden', $$select count(*)::text from search_offers(null,null,null,null,null,null,100,0) s join offerings o on o.id = s.id where not o.active or o.moderation_hidden$$, '0');

\echo '===== course_seats = the seats_overview rows the pages summed (bookings without a meeting)'
select t_is('every offer', $$select ((select coalesce(string_agg(offering_id || ':' || taken, ',' order by offering_id), '') from course_seats())
          = (select coalesce(string_agg(offering_id || ':' || taken, ',' order by offering_id), '') from seats_overview() where session_id is null))::text$$, 'true');
select t_is('one institute', $$select ((select coalesce(sum(taken), 0) from course_seats(null, (select id from institutes where name = 'مركز النخبة للتعليم')))
          = (select coalesce(sum(s.taken), 0) from seats_overview() s join offerings o on o.id = s.offering_id where s.session_id is null and o.institute_id = (select id from institutes where name = 'مركز النخبة للتعليم')))::text$$, 'true');
select t_err('visitors cannot count students of a dashboard', $$select owner_student_count()$$);
reset role;

\echo '===== dashboards'
set role authenticated; set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000002';
select t_is('owner_student_count = distinct confirmed students of owner_bookings', $$select (owner_student_count() = (select count(distinct student_name) from owner_bookings() where status = 'confirmed'))::text$$, 'true');
select t_is('lessons from a date: old open requests are kept', $$select count(*)::text from owner_bookings(null, now()) where status = 'pending' and created_at < now() - interval '30 days'$$, '1');
select t_is('lessons from a date: old confirmed ones are dropped', $$select count(*)::text from owner_bookings(null, now() + interval '400 days') where status = 'confirmed'$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub = 'c0000000-0000-0000-0000-000000000004';
select t_err('my_conversation_ids is internal (no direct calls)', $$select * from my_conversation_ids()$$);
select t_ok('header counts still work', $$select * from my_header_counts()$$);
reset role;
