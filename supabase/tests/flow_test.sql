\set ON_ERROR_STOP 0
\pset pager off
-- accounts
insert into auth.users (id, email, raw_user_meta_data) values
 ('00000000-0000-0000-0000-00000000000a','parent@test','{"full_name":"عائلة خطيب"}'),
 ('00000000-0000-0000-0000-00000000000b','samer@test','{"full_name":"سامر مصاروة"}'),
 ('00000000-0000-0000-0000-00000000000c','nukhba@test','{"full_name":"مركز النخبة"}');
update teachers set user_id='00000000-0000-0000-0000-00000000000b' where name='سامر مصاروة';
update institutes set owner_id='00000000-0000-0000-0000-00000000000c' where name='مركز النخبة للتعليم';

select 'counts' t, (select count(*) from teachers) teachers, (select count(*) from offerings) offerings,
       (select count(*) from sessions) sessions, (select count(*) from profiles) profiles;
select o.title, count(s.*) n, min(s.starts_at at time zone 'Asia/Jerusalem') first from offerings o join sessions s on s.offering_id=o.id where o.type='course' group by o.title;

-- anon
set role anon; reset request.jwt.claim.sub;
select 'anon sees offerings' t, count(*) from offerings;
select 'anon sees bookings' t, count(*) from bookings;
select 'anon books (expect error)' t; select create_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'));
reset role;

-- parent
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000a';
insert into children (guardian_id, name, grade) values ('00000000-0000-0000-0000-00000000000a','يوسف','صف 12');
select 'private booking' t, create_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), (select id from children where name='يوسف'), ((date_trunc('week', now()) + interval '13 days 17 hours')::timestamp at time zone 'Asia/Jerusalem'), null, 'bit') is not null ok;
select 'double booking (expect error)' t; select create_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), null, ((date_trunc('week', now()) + interval '13 days 17 hours')::timestamp at time zone 'Asia/Jerusalem'));
select 'group seat' t, create_booking((select id from offerings where title like 'مجموعة تقوية رياضيات%'), null, null, (select s.id from sessions s join offerings o on o.id=s.offering_id where o.title like 'مجموعة تقوية رياضيات%' order by seq limit 1)) is not null ok;
select 'course enrol' t, create_booking((select id from offerings where title='دورة بجروت رياضيات 5 وحدات'), (select id from children where name='يوسف'), null, null, '3 دفعات') is not null ok;
select 'parent sees own bookings' t, count(*) from bookings;
select 'parent cannot reschedule (expect error)' t; select reschedule_session((select s.id from sessions s join offerings o on o.id=s.offering_id where o.title='دورة بجروت رياضيات 5 وحدات' and seq=3), now()+interval '30 days');
reset role;

-- teacher
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000b';
select 'teacher notifications' t, body from notifications order by created_at;
select 'teacher sees bookings' t, count(*) from bookings;
select 'accept' t, respond_booking((select b.id from bookings b join offerings o on o.id=b.offering_id where o.type='private'), true);
reset role;

-- institute: clash, then a valid move of all following sessions
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000c';
select 'clash (expect error)' t;
select reschedule_session(
  (select s.id from sessions s join offerings o on o.id=s.offering_id where o.title='دورة بجروت رياضيات 5 وحدات' and seq=3),
  (select starts_at from sessions s join offerings o on o.id=s.offering_id where o.title='تحضير بسيخومتري مكثّف' and seq=1),
  (select id from rooms where name='قاعة 3'));
select 'move following' t, reschedule_session(
  (select s.id from sessions s join offerings o on o.id=s.offering_id where o.title='دورة بجروت رياضيات 5 وحدات' and seq=3),
  (select starts_at + interval '1 hour' from sessions s join offerings o on o.id=s.offering_id where o.title='دورة بجروت رياضيات 5 وحدات' and seq=3),
  null, 'following', 'امتحانات في المدارس') moved;
select 'log' t, body, notified_count from change_log;
reset role;

set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000a';
select 'parent notifications' t, body from notifications order by created_at;
reset role;
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000b';
select 'teacher notification' t, body from notifications where kind='schedule_changed';
reset role;
select seq, to_char(starts_at at time zone 'Asia/Jerusalem','Dy DD/MM HH24:MI') at, changed from sessions s join offerings o on o.id=s.offering_id where o.title='دورة بجروت رياضيات 5 وحدات' order by seq limit 5;

-- photos and admin
update profiles set roles = '{guardian,admin}' where id='00000000-0000-0000-0000-00000000000a';

set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000b';
select 'upload own folder' t; insert into storage.objects (bucket_id, name) values ('avatars','00000000-0000-0000-0000-00000000000b/teacher.jpg');
select 'upload other folder (expect error)' t; insert into storage.objects (bucket_id, name) values ('avatars','00000000-0000-0000-0000-00000000000a/x.jpg');
select 'teacher self-verify (expect error)' t; select admin_verify('teacher', (select id from teachers where name='سامر مصاروة'), 'verified');
reset role;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000d','new@test');
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000d';
insert into teachers (user_id, name, town) values ('00000000-0000-0000-0000-00000000000d','معلمة جديدة','الطيرة');
reset role;
set role authenticated; set request.jwt.claim.sub='00000000-0000-0000-0000-00000000000a';
select 'admin sees pending' t, name, verify from teachers where verify='pending';
select 'admin verifies' t, admin_verify('teacher', (select id from teachers where name='معلمة جديدة'), 'verified');
reset role;
select 'after' t, name, verify from teachers where name='معلمة جديدة';
select 'new teacher notified' t, body from notifications where user_id='00000000-0000-0000-0000-00000000000d';
