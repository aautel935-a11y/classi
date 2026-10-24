\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000003','rana@t','{"full_name":"رنا"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000005','dad@t','{"full_name":"أبو آدم"}'),
 ('40000000-0000-0000-0000-000000000007','owner@t','{"full_name":"صاحب المعهد"}');
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
update teachers set user_id='40000000-0000-0000-0000-000000000003' where name='رنا أبو حسين';
update institutes set owner_id='40000000-0000-0000-0000-000000000007' where name='معهد المستقبل';
insert into children (id, guardian_id, name) values ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000004','يوسف');
create temp table ids as select
  (select id from offerings where title='رياضيات بجروت 5 وحدات') priv,
  (select id from offerings where title='مجموعة أونلاين، تحضير الشفوي') grp,
  (select id from offerings where title='إنجليزي محادثة للإعدادي') crs;
grant select on ids to authenticated;
-- a private lesson that ended an hour ago, one tomorrow; a group meeting that just happened with two students; a course meeting
insert into bookings (id, offering_id, booked_by, child_id, starts_at, minutes, status, mode) values
 ('60000000-0000-0000-0000-000000000001', (select priv from ids), '40000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000001', now() - interval '2 hours', 60, 'confirmed', 'home'),
 ('60000000-0000-0000-0000-000000000002', (select priv from ids), '40000000-0000-0000-0000-000000000005', null, now() + interval '1 day', 60, 'confirmed', 'home');
update sessions set starts_at = now() - interval '2 hours' where id = (select id from sessions where offering_id = (select grp from ids) order by starts_at limit 1);
insert into bookings (offering_id, session_id, booked_by, child_id, minutes, status, mode)
 select (select grp from ids), id, u, c, 60, 'confirmed', 'online' from sessions,
   (values ('40000000-0000-0000-0000-000000000004'::uuid, '50000000-0000-0000-0000-000000000001'::uuid), ('40000000-0000-0000-0000-000000000005'::uuid, null::uuid)) v(u, c)
  where offering_id = (select grp from ids) order by starts_at limit 2;
update sessions set starts_at = now() - interval '3 hours' where id = (select id from sessions where offering_id = (select crs from ids) order by starts_at limit 1);
insert into bookings (offering_id, booked_by, minutes, status, mode) values ((select crs from ids), '40000000-0000-0000-0000-000000000005', 90, 'confirmed', 'center');
update offerings set course_teacher_id = (select id from teachers where name='رنا أبو حسين') where id = (select crs from ids);
delete from notifications; delete from reminder_log;

\echo '===== 1. Reminders to write reports'
select 'reminders' t, report_reminders() n;
select p.full_name, n.body, n.link like '/teach/report?%' ok_link from notifications n join profiles p on p.id = n.user_id order by 1;

\echo '===== 2. Samer: pending list, then writes the private report'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'pending' t, kind, title, who, students from pending_reports();
select 'write' t, write_lesson_report('60000000-0000-0000-0000-000000000001', null, 'راجعنا المعادلات التربيعية وحللنا 8 تمارين', 'تمارين 1-10 صفحة 45', 4, 5, 'تقدم ممتاز، يحتاج انتباه للإشارات') is not null;
select 'future lesson (expect error)' t;
select write_lesson_report('60000000-0000-0000-0000-000000000002', null, 'x');
select 'empty (expect error)' t;
select write_lesson_report('60000000-0000-0000-0000-000000000001', null, '  ');
select 'pending after' t, count(*) from pending_reports() where kind = 'private';
reset role;

\echo '===== 3. Rana writes the group meeting: one present, one absent'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
select 'session students' t, who, report_id is null no_report from session_students((select id from sessions where offering_id = (select grp from ids) order by starts_at limit 1));
select 'group reports' t, write_session_reports((select id from sessions where offering_id = (select grp from ids) order by starts_at limit 1),
  'تدربنا على أسئلة الشفوي عن الهوايات', 'حضّر دقيقتين عن عائلتك',
  (select jsonb_agg(jsonb_build_object('booking_id', booking_id, 'present', who = 'يوسف', 'understanding', 3, 'participation', 4, 'note', case when who = 'يوسف' then 'شارك بثقة' end))
     from session_students((select id from sessions where offering_id = (select grp from ids) order by starts_at limit 1))));
select 'samer cannot write rana''s (expect error)' t;
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select write_lesson_report((select id from bookings where session_id is not null limit 1), null, 'x');
reset role;

\echo '===== 4. Course teacher (Rana) reports the institute course meeting'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
select 'course' t, write_session_reports((select id from sessions where offering_id = (select crs from ids) order by starts_at limit 1), 'محادثة في المطعم', null,
  (select jsonb_agg(jsonb_build_object('booking_id', booking_id, 'understanding', 5)) from session_students((select id from sessions where offering_id = (select crs from ids) order by starts_at limit 1))));
select 'attendance kept' t, count(*) from attendance;
reset role;

\echo '===== 5. Parents read their reports'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'mom notifications' t, body, want_push from notifications where user_id = auth.uid() order by created_at;
select 'mom reports' t, title, child_name, present, understanding, homework from my_reports();
select 'mom sees only hers' t, count(*) from lesson_reports;
select mark_report_read((select id from my_reports() limit 1));
select 'read' t, count(*) from lesson_reports where read_at is not null;
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select 'dad reports' t, title, present, summary from my_reports();
reset role;
\echo '===== 6. Editing re-notifies'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select write_lesson_report('60000000-0000-0000-0000-000000000001', null, 'راجعنا المعادلات التربيعية', 'تمارين 1-12', 4, 5, null) is not null;
reset role;
select 'edit notice' t, body from notifications where user_id='40000000-0000-0000-0000-000000000004' and body like 'حدّث%';
select 'reminders again (expect 0 new)' t, report_reminders();
