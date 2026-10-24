\pset pager off
\pset footer off
-- Accounts: admin, new online teacher, new institute owner, guardian, a second guardian, an outsider teacher
insert into auth.users (id, email, raw_user_meta_data) values
 ('10000000-0000-0000-0000-000000000001','admin@t','{"full_name":"مدير المنصة"}'),
 ('10000000-0000-0000-0000-000000000002','zoom@t','{"full_name":"هالة زوم"}'),
 ('10000000-0000-0000-0000-000000000003','inst@t','{"full_name":"معهد الأمل"}'),
 ('10000000-0000-0000-0000-000000000004','parent@t','{"full_name":"أم آدم"}'),
 ('10000000-0000-0000-0000-000000000005','other@t','{"full_name":"أب آخر"}');
update profiles set roles='{guardian,admin}' where id='10000000-0000-0000-0000-000000000001';

\echo '===== 1. ONLINE TEACHER signs up and builds a profile'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000002';
update profiles set roles='{teacher}', active_role='teacher' where id=auth.uid();
insert into teachers (user_id,name,town,subject_id,bio,years,verify,rating) values (auth.uid(),'هالة زوم','الطيبة',2,'إنجليزي أونلاين عبر زوم',4,'verified',5.0);
select 'self-verify blocked?' t, verify, rating from teachers where user_id=auth.uid();
select 'default availability rows' t, count(*) from availability where teacher_id=my_teacher_id();
insert into offerings (type,teacher_id,title,subject_id,level_id,places,price,minutes)
  values ('private',my_teacher_id(),'إنجليزي محادثة عبر زوم',2,3,'{online}',120,60);
insert into offerings (type,teacher_id,title,subject_id,level_id,places,price,seats,schedule_note,minutes)
  values ('group',my_teacher_id(),'مجموعة زوم للبجروت',2,5,'{online}',45,8,'كل اثنين 19:00',90);
insert into sessions (offering_id,seq,starts_at,minutes)
  select id,1,now()+interval '3 days',90 from offerings where title='مجموعة زوم للبجروت';
reset role;

\echo '===== 2. VISITOR before approval'
set role anon; reset request.jwt.claim.sub;
select 'anon sees pending teacher' t, count(*) from teachers where name='هالة زوم';
select 'anon sees her offers (should be 0)' t, count(*) from offerings where title like '%زوم%';
reset role;

\echo '===== 3. PARENT tries to book an unapproved teacher (should be refused)'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000004';
insert into children (guardian_id,name,grade) values (auth.uid(),'آدم','صف 11');
select create_booking((select id from offerings where title='إنجليزي محادثة عبر زوم'), (select id from children where name='آدم'),
  ((current_date + 2) + time '17:00') at time zone 'Asia/Jerusalem');
reset role;

\echo '===== 4. ADMIN approves'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000001';
select 'admin pending list' t, name, verify from teachers where verify<>'verified';
select admin_verify('teacher',(select id from teachers where name='هالة زوم'),'verified');
reset role;
set role anon; reset request.jwt.claim.sub;
select 'anon sees teacher after approval' t, count(*) from teachers where name='هالة زوم';
reset role;

\echo '===== 5. INSTITUTE OWNER sets up, adds staff, creates a course'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000003';
update profiles set roles='{institute}', active_role='institute' where id=auth.uid();
insert into institutes (owner_id,name,town,bio) values (auth.uid(),'معهد الأمل','باقة الغربية','دورات تقوية');
insert into rooms (institute_id,name) select id,'قاعة أ' from institutes where owner_id=auth.uid();
insert into institute_teachers select i.id,t.id from institutes i, teachers t where i.owner_id=auth.uid() and t.name='هالة زوم';
insert into offerings (type,institute_id,course_teacher_id,title,subject_id,level_id,places,price,seats,schedule_note,start_date,sessions_count,minutes,default_room_id)
  select 'course',i.id,t.id,'دورة إنجليزي مكثفة',2,5,'{center,online}',600,10,'الأحد 18:00',current_date+5,3,90,r.id
  from institutes i join rooms r on r.institute_id=i.id, teachers t where i.owner_id=auth.uid() and t.name='هالة زوم';
insert into sessions (offering_id,seq,starts_at,minutes,room_id)
  select o.id,g,(current_date+5+7*(g-1)+time '18:00') at time zone 'Asia/Jerusalem',90,o.default_room_id from offerings o, generate_series(1,3) g where o.title='دورة إنجليزي مكثفة';
select 'course sessions' t, count(*) from sessions s join offerings o on o.id=s.offering_id where o.title='دورة إنجليزي مكثفة';
reset role;

\echo '===== 6. ADMIN approves the institute'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000001';
select admin_verify('institute',(select id from institutes where name='معهد الأمل'),'verified');
reset role;

\echo '===== 7. PARENT books: private Zoom lesson, group seat, course, recorded'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000004';
select 'private' t, create_booking((select id from offerings where title='إنجليزي محادثة عبر زوم'), (select id from children where name='آدم'),
  ((current_date + 2) + time '17:00') at time zone 'Asia/Jerusalem') is not null ok;
select 'group' t, create_booking((select id from offerings where title='مجموعة زوم للبجروت'), null, null,
  (select s.id from sessions s join offerings o on o.id=s.offering_id where o.title='مجموعة زوم للبجروت')) is not null ok;
select 'course' t, create_booking((select id from offerings where title='دورة إنجليزي مكثفة'), (select id from children where name='آدم'), null, null, 'installments') is not null ok;
select 'recorded' t, create_booking((select id from offerings where title like 'الدوال من الصفر%')) is not null ok;
select 'parent schedule' t, o.title, b.status from bookings b join offerings o on o.id=b.offering_id order by o.title;
reset role;

\echo '===== 8. TEACHER sees requests, accepts the Zoom lesson'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000002';
select 'teacher notifications' t, body from notifications order by created_at;
select 'teacher bookings' t, offering_title, student_name, status from owner_bookings();
select respond_booking((select booking_id from owner_bookings() where status='pending' limit 1), true);
select 'course teacher sees course sessions' t, count(*) from sessions s join offerings o on o.id=s.offering_id where o.course_teacher_id=my_teacher_id();
select 'course teacher sees course roster (owner_bookings)' t, count(*) from owner_bookings((select id from offerings where title='دورة إنجليزي مكثفة'));
select 'course teacher marks attendance' t;
insert into attendance select s.id, b.id, true from sessions s, bookings b where s.seq=1 and s.offering_id=(select id from offerings where title='دورة إنجليزي مكثفة') and b.offering_id=s.offering_id;
reset role;

\echo '===== 9. INSTITUTE moves the course, attendance'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000003';
select 'moved' t, reschedule_session((select s.id from sessions s join offerings o on o.id=s.offering_id where o.title='دورة إنجليزي مكثفة' and seq=2),
  (select starts_at + interval '30 minutes' from sessions s join offerings o on o.id=s.offering_id where o.title='دورة إنجليزي مكثفة' and seq=2), null,'following','عطلة');
select 'institute roster' t, student_name, status, pay_method from owner_bookings();
reset role;

\echo '===== 10. Notifications after the move'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000004';
select 'parent' t, body from notifications order by created_at;
reset role;
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000002';
select 'teacher' t, body from notifications where kind='schedule_changed';
reset role;

\echo '===== 11. PRIVACY: another parent'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000005';
select 'other parent sees bookings' t, count(*) from bookings;
select 'other parent sees children' t, count(*) from children;
select 'other parent sees notifications' t, count(*) from notifications;
select 'other parent accepts a request (expect error)' t;
select respond_booking((select id from bookings limit 1), true);
reset role;

\echo '===== 12. PARENT cancels the accepted lesson within 24h? (lesson is in 2 days, allowed)'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000004';
select cancel_booking((select b.id from bookings b join offerings o on o.id=b.offering_id where o.title='إنجليزي محادثة عبر زوم'));
select 'after cancel' t, o.title, b.status from bookings b join offerings o on o.id=b.offering_id order by o.title;
reset role;

\echo '===== 13. ZOOM LINK visibility'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000002';
insert into offering_links (offering_id,url) select id,'https://zoom.us/j/123456' from offerings where title='مجموعة زوم للبجروت';
insert into offering_links (offering_id,url) select id,'https://zoom.us/j/999' from offerings where title='إنجليزي محادثة عبر زوم';
select 'course teacher attendance rows' t, count(*) from attendance;
reset role;
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000004';
select 'parent sees links for confirmed only' t, o.title, l.url from offering_links l join offerings o on o.id=l.offering_id;
reset role;
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000005';
select 'other parent sees links' t, count(*) from offering_links;
reset role;
set role anon; reset request.jwt.claim.sub;
select 'anon sees links' t, count(*) from offering_links;
reset role;
\echo '===== 14. MODE + self-booking'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000004';
select 'home on online-only offer (expect error)' t;
select create_booking((select id from offerings where title='إنجليزي محادثة عبر زوم'), null, ((current_date + 3) + time '18:00') at time zone 'Asia/Jerusalem', null, 'bit', false, 'home');
select 'online mode on Samer (home+online)' t, create_booking((select id from offerings where title='رياضيات بجروت 5 وحدات'), null, ((current_date + 3) + time '18:00') at time zone 'Asia/Jerusalem', null, 'bit', false, 'online') is not null ok;
reset role;
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000002';
select 'teacher books own offer (expect error)' t;
select create_booking((select id from offerings where title='مجموعة زوم للبجروت'), null, null, (select s.id from sessions s join offerings o on o.id=s.offering_id where o.title='مجموعة زوم للبجروت'));
reset role;
\echo '===== 15. SIGNUP keeps town and role'
insert into auth.users (id, email, raw_user_meta_data) values ('10000000-0000-0000-0000-000000000009','new@t','{"full_name":"جديد","town":"جت","role":"teacher"}');
select 'new profile' t, full_name, town, roles, active_role from profiles where id='10000000-0000-0000-0000-000000000009';
insert into auth.users (id, email, raw_user_meta_data) values ('10000000-0000-0000-0000-000000000010','hack@t','{"role":"admin"}');
select 'admin via signup blocked' t, roles from profiles where id='10000000-0000-0000-0000-000000000010';
\echo '===== 16. Link notifications + hidden offer stays in schedule'
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000004';
select 'parent link notifications' t, body from notifications where kind='link';
reset role;
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000002';
update offerings set active=false where title='مجموعة زوم للبجروت';
reset role;
set role authenticated; set request.jwt.claim.sub='10000000-0000-0000-0000-000000000004';
select 'parent still sees hidden booked offer' t, count(*) from offerings where title='مجموعة زوم للبجروت';
reset role;
set role anon; reset request.jwt.claim.sub;
select 'anon sees hidden offer' t, count(*) from offerings where title='مجموعة زوم للبجروت';
reset role;
