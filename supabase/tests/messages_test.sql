\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('20000000-0000-0000-0000-000000000001','admin@t','{"full_name":"المدير"}'),
 ('20000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('20000000-0000-0000-0000-000000000003','nukhba@t','{"full_name":"النخبة"}'),
 ('20000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('20000000-0000-0000-0000-000000000005','stranger@t','{"full_name":"غريب"}');
update profiles set roles='{guardian,admin}' where id='20000000-0000-0000-0000-000000000001';
update teachers set user_id='20000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
update institutes set owner_id='20000000-0000-0000-0000-000000000003' where name='مركز النخبة للتعليم';

\echo '===== EDIT: teacher changes price; old booking keeps its price'
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000004';
select create_booking((select id from offerings where title like 'مجموعة تقوية رياضيات%'), null, null,
  (select s.id from sessions s join offerings o on o.id=s.offering_id where o.title like 'مجموعة تقوية رياضيات%' order by seq limit 1)) is not null booked;
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000002';
update offerings set price = 75, title = 'مجموعة تقوية رياضيات، صف عاشر (محدّث)' where title like 'مجموعة تقوية رياضيات%';
select 'new price' t, price from offerings where title like 'مجموعة تقوية رياضيات%';
select 'seats to 0 (expect error)' t; update offerings set seats = 0 where title like 'مجموعة تقوية رياضيات%';
select 'type change (expect error)' t; update offerings set type='private' where title like 'مجموعة تقوية رياضيات%';
select 'edit someone else (0 rows)' t; update offerings set price = 1 where title = 'إنجليزي محادثة وبجروت' returning id;
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000004';
select 'booking keeps old price' t, b.price from bookings b;
reset role;

\echo '===== MESSAGES: parent writes to Samer'
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000004';
select start_conversation((select id from teachers where name='سامر مصاروة')) is not null started;
insert into messages (conversation_id, body) values ((select id from conversations), 'مرحباً أستاذ، أين تكون الحصة؟');
select 'same conversation again' t, start_conversation((select id from teachers where name='سامر مصاروة')) = (select id from conversations) same;
select 'message teacher without account (expect error)' t; select start_conversation((select id from teachers where name='رنا أبو حسين'));
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000002';
select 'teacher inbox' t, other_name, last_body, unread, i_am_owner from my_conversations();
select 'teacher notification' t, body, link like '/messages/%' ok from notifications where kind='message';
insert into messages (conversation_id, body) values ((select id from conversations), 'أهلاً، في بيتي في باقة، الشارع الرئيسي');
select mark_conversation_read((select id from conversations));
select 'after read' t, unread from my_conversations();
select 'teacher notifications unread' t, count(*) from notifications where kind='message' and read_at is null;
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000004';
select 'parent inbox' t, other_name, last_body, unread from my_conversations();
insert into messages (conversation_id, body) values ((select id from conversations), 'شكراً');
insert into messages (conversation_id, body) values ((select id from conversations), 'نراك الثلاثاء');
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000002';
select 'one notice per conversation' t, count(*) from notifications where kind='message' and read_at is null;
reset role;

\echo '===== PRIVACY'
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000005';
select 'stranger sees conversations' t, count(*) from conversations;
select 'stranger sees messages' t, count(*) from messages;
select 'stranger writes into it (expect error)' t;
insert into messages (conversation_id, body) select id, 'spam' from conversations;
insert into messages (conversation_id, body) values ((select id from conversations limit 1), 'x');
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000004';
select 'spoof sender (expect error)' t;
insert into messages (conversation_id, sender_id, body) values ((select id from conversations), '20000000-0000-0000-0000-000000000002', 'fake');
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000001';
select 'admin before report' t, count(*) from messages;
reset role;

\echo '===== REPORT'
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000004';
insert into conversation_reports (conversation_id, reason) values ((select id from conversations), 'اختبار');
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000001';
select 'admin notified' t, body from notifications where kind='report';
select 'admin reads reported messages' t, count(*) from messages;
reset role;

\echo '===== INSTITUTE starts a conversation from a booking'
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000004';
select create_booking((select id from offerings where title='دورة بجروت رياضيات 5 وحدات')) is not null enrolled;
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000003';
select 'institute opens chat with booker' t, start_conversation_for_booking((select booking_id from owner_bookings() limit 1)) is not null ok;
select 'institute inbox' t, other_name, i_am_owner from my_conversations();
reset role;
set role authenticated; set request.jwt.claim.sub='20000000-0000-0000-0000-000000000002';
select 'teacher opens chat for a booking not his (expect error)' t;
select start_conversation_for_booking((select id from bookings b where b.offering_id=(select id from offerings where title='دورة بجروت رياضيات 5 وحدات')));
reset role;
