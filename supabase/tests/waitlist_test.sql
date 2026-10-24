\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000003','rana@t','{"full_name":"رنا"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000005','dad@t','{"full_name":"أبو آدم"}'),
 ('40000000-0000-0000-0000-000000000006','sara@t','{"full_name":"سارة"}'),
 ('40000000-0000-0000-0000-000000000007','owner@t','{"full_name":"صاحب المعهد"}');
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
update teachers set user_id='40000000-0000-0000-0000-000000000003' where name='رنا أبو حسين';
update institutes set owner_id='40000000-0000-0000-0000-000000000007' where name='معهد المستقبل';
create temp table g as select id from offerings where title='مجموعة أونلاين، تحضير الشفوي';
create temp table c as select id from offerings where title='إنجليزي محادثة للإعدادي';
create temp table p as select id from offerings where title='رياضيات بجروت 5 وحدات';
grant select on g, c, p to authenticated;
update offerings set seats = 1 where id = (select id from g);
update offerings set seats = 1 where id = (select id from c);

\echo '===== 1. Group full: mom takes the only seat of every meeting? no, of meeting 1; group shown full'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select create_booking((select id from g), null, null, (select id from sessions where offering_id=(select id from g) and starts_at>now() order by starts_at limit 1)) is not null mom_booked;
reset role;

\echo '===== 2. Dad and Sara join the line'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select 'dad position' t, join_waitlist((select id from g), null, 'أي يوم بعد الساعة 5') pos;
select 'dad again (expect error)' t;
select join_waitlist((select id from g));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000006';
select 'sara position' t, join_waitlist((select id from g)) pos;
select 'sara sees' t, offering_title, pos, status from my_waitlist();
select 'sara sees others rows? (expect 1 = own)' t, count(*) from waitlist;
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
select 'rana told' t, body from notifications where kind='waitlist_join' order by created_at;
select 'rana list' t, student_name, note, pos from owner_waitlist();
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'mom cannot read the line (expect 0)' t, count(*) from waitlist;
select 'mom cannot answer (expect error)' t;
select respond_waitlist((select id from waitlist limit 1), true);
reset role;

\echo '===== 3. Mom cancels -> first in line (dad) hears, Sara keeps waiting'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select cancel_booking((select id from bookings where booked_by=auth.uid() limit 1));
reset role;
select 'statuses' t, p.full_name, w.status from waitlist w join profiles p on p.id=w.user_id order by w.created_at;
select 'dad told' t, body from notifications where kind='waitlist_open';

\echo '===== 4. Dad books the freed seat -> his line entry becomes booked'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select create_booking((select id from g), null, null, (select id from sessions where offering_id=(select id from g) and starts_at>now() order by starts_at limit 1)) is not null dad_booked;
select 'dad line' t, status from waitlist where user_id=auth.uid();
reset role;

\echo '===== 5. Rana adds a seat -> Sara hears'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
update offerings set seats = 2 where id = (select id from g);
reset role;
select 'sara' t, w.status, (select body from notifications n where n.user_id=w.user_id and kind='waitlist_open') from waitlist w where user_id='40000000-0000-0000-0000-000000000006';

\echo '===== 6. Course full: institute accepts one (extra seat), declines another'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select create_booking((select id from c)) is not null mom_in_course;
select 'mom joins her own course line (expect error)' t;
select join_waitlist((select id from c));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select join_waitlist((select id from c));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000006';
select join_waitlist((select id from c));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000007';
select 'owner list' t, student_name, pos from owner_waitlist((select id from c));
select respond_waitlist((select id from owner_waitlist((select id from c)) where pos=1), true);
select respond_waitlist((select id from owner_waitlist((select id from c)) where pos=1), false, 'الدورة القادمة تبدأ في الشهر القادم');
select 'course roster' t, student_name, status from owner_bookings((select id from c));
reset role;
select 'answers' t, p.full_name, n.body from notifications n join profiles p on p.id=n.user_id where kind='waitlist_answer' order by n.created_at;

\echo '===== 7. Private: no free hours; Samer replies -> conversation; new hours notify'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select join_waitlist((select id from p), null, 'الأحد أو الثلاثاء مساءً');
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000006';
select join_waitlist((select id from p));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'conversation' t, respond_waitlist((select id from owner_waitlist((select id from p)) where pos=1), true, 'أهلاً، عندي مكان الخميس 18:00، يناسبك؟') is not null;
select 'notified by new hours' t, waitlist_hours_opened();
reset role;
select 'mom msg' t, m.body from messages m join conversations cv on cv.id=m.conversation_id where cv.user_id='40000000-0000-0000-0000-000000000004';
select 'private line' t, p.full_name, w.status from waitlist w join profiles p on p.id=w.user_id where offering_id=(select id from p) order by w.created_at;

\echo '===== 8. Leave the line'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000006';
select leave_waitlist((select id from waitlist where user_id=auth.uid() and offering_id=(select id from p)));
select 'sara open entries' t, offering_title, status from my_waitlist();
reset role;
