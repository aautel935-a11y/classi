\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('30000000-0000-0000-0000-000000000001','admin@t','{"full_name":"المدير"}'),
 ('30000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('30000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('30000000-0000-0000-0000-000000000005','troll@t','{"full_name":"مزعج"}');
update profiles set roles='{guardian,admin}' where id='30000000-0000-0000-0000-000000000001';
update teachers set user_id='30000000-0000-0000-0000-000000000002' where name='سامر مصاروة';

\echo '===== REPORTS'
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000004';
insert into reports (target_type, target_id, reason, details) values ('teacher',(select id from teachers where name='سامر مصاروة'),'no_show','لم يحضر الحصة');
select 'duplicate report (expect error)' t;
insert into reports (target_type, target_id, reason) values ('teacher',(select id from teachers where name='سامر مصاروة'),'other');
select 'parent sees own reports only' t, count(*) from reports;
select 'parent calls admin_reports (expect error)' t; select * from admin_reports();
reset role;
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000001';
select 'admin notified' t, body from notifications where kind='report';
select 'admin queue' t, target_type, target_name, reason, reporter_name, same_target_open from admin_reports();
select 'user list' t, full_name, email, status, open_reports from admin_users('سامر');
reset role;

\echo '===== HIDE AN OFFER AND A TEACHER'
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000001';
select admin_hide('offering', (select id from offerings where title='رياضيات بجروت 5 وحدات'), true, 'وصف مضلل');
reset role;
set role anon; reset request.jwt.claim.sub;
select 'anon sees hidden offer' t, count(*) from offerings where title='رياضيات بجروت 5 وحدات';
reset role;
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000002';
select 'owner told' t, body from notifications where kind='moderation';
select 'owner un-hides himself (should stay hidden)' t; update offerings set moderation_hidden=false where title='رياضيات بجروت 5 وحدات';
reset role;
select 'still hidden' t, moderation_hidden from offerings where title='رياضيات بجروت 5 وحدات';
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000001';
select admin_hide('teacher', (select id from teachers where name='سامر مصاروة'), true, null);
reset role;
set role anon; reset request.jwt.claim.sub;
select 'anon sees Samer + his offers' t, (select count(*) from teachers where name='سامر مصاروة') teacher, (select count(*) from offerings o join teachers t on t.id=o.teacher_id where t.name='سامر مصاروة') offers;
reset role;
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000001';
select admin_hide('teacher', (select id from teachers where name='سامر مصاروة'), false, null);
select admin_hide('offering', (select id from offerings where title='رياضيات بجروت 5 وحدات'), false, null);
reset role;

\echo '===== SUSPEND AND BAN'
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000001';
select admin_set_user_status('30000000-0000-0000-0000-000000000005','suspended',3,'رسائل مزعجة');
select 'ban myself (expect error)' t; select admin_set_user_status('30000000-0000-0000-0000-000000000001','banned');
reset role;
select 'troll status' t, p.status, p.suspended_until > now() + interval '2 days' as three_days, u.banned_until is not null as login_blocked from profiles p join auth.users u on u.id=p.id where p.id='30000000-0000-0000-0000-000000000005';
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000005';
select 'suspended books (expect error)' t;
select create_booking((select id from offerings where title='إنجليزي محادثة وبجروت' limit 1), null, ((current_date + 4) + time '16:00') at time zone 'Asia/Jerusalem');
select 'suspended reports (expect error)' t;
insert into reports (target_type, target_id, reason) values ('teacher',(select id from teachers where name='سامر مصاروة'),'other');
select 'suspended self-reactivates (should stay suspended)' t; update profiles set status='active' where id=auth.uid();
reset role;
select 'after self attempt' t, status from profiles where id='30000000-0000-0000-0000-000000000005';
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000001';
select admin_set_user_status('30000000-0000-0000-0000-000000000002','banned',null,'احتيال');
reset role;
set role anon; reset request.jwt.claim.sub;
select 'anon sees banned teacher' t, count(*) from teachers where name='سامر مصاروة';
reset role;
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000001';
select admin_set_user_status('30000000-0000-0000-0000-000000000002','active');
select admin_close_report((select id from reports limit 1),'resolved','تم التواصل مع المعلم');
select 'log' t, target_type, action, reason from moderation_actions order by created_at;
reset role;
select 'samer back' t, p.status, u.banned_until from profiles p join auth.users u on u.id=p.id where p.id='30000000-0000-0000-0000-000000000002';
set role anon; reset request.jwt.claim.sub;
select 'anon sees Samer again' t, count(*) from teachers where name='سامر مصاروة';
select 'health ping' t, ok, offerings > 0 from health_ping();
reset role;
set role authenticated; set request.jwt.claim.sub='30000000-0000-0000-0000-000000000002';
select 'header counts' t, * from my_header_counts();
reset role;
