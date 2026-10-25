\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000003','rana@t','{"full_name":"رنا"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف","phone":"0501234567"}'),
 ('40000000-0000-0000-0000-000000000007','owner@t','{"full_name":"صاحب المعهد"}');
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
update teachers set user_id='40000000-0000-0000-0000-000000000003' where name='رنا أبو حسين';
update institutes set owner_id='40000000-0000-0000-0000-000000000007' where name='معهد المستقبل';
create temp table ids as select (select id from offerings where title='مجموعة أونلاين، تحضير الشفوي') grp,
  (select id from offerings where title='إنجليزي محادثة للإعدادي') crs, (select id from offerings where title='رياضيات بجروت 5 وحدات') priv,
  (select id from teachers where name='رنا أبو حسين') rana;
grant select on ids to authenticated;
insert into institute_teachers values ((select id from institutes where name='معهد المستقبل'), (select rana from ids)) on conflict do nothing;
update offerings set course_teacher_id = (select rana from ids) where id = (select crs from ids);
delete from notifications;

\echo '===== 1. Group meetings: only 8 seeded; the daily job keeps 8 weeks ahead'
select 'before' t, count(*) from sessions where offering_id = (select grp from ids);
-- pretend the group started 6 weeks ago: shift its meetings back
update sessions set starts_at = starts_at - interval '6 weeks' where offering_id = (select grp from ids);
select 'future before job' t, count(*) from sessions where offering_id = (select grp from ids) and starts_at > now();
select 'added' t, extend_group_sessions();
select 'future after job' t, count(*), to_char(min(starts_at) at time zone 'Asia/Jerusalem','Dy HH24:MI') first_, to_char(max(starts_at) at time zone 'Asia/Jerusalem','Dy HH24:MI') last_
  from sessions where offering_id = (select grp from ids) and starts_at > now();
select 'again (expect 0)' t, extend_group_sessions();

\echo '===== 2. Mom has a weekly group seat; Rana cancels next meeting'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
update offerings set allow_weekly = true where id = (select grp from ids);
reset role;
update offerings set allow_weekly = true where id = (select grp from ids);
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'weekly' t, create_weekly_booking((select grp from ids), null, null, (select id from sessions where offering_id = (select grp from ids) and starts_at > now() order by starts_at limit 1)) ->> 'created' created;
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
select 'cancel meeting' t, cancel_session((select id from sessions where offering_id = (select grp from ids) and starts_at > now() order by starts_at limit 1), 'عيد');
select 'cancel past (expect error)' t;
select cancel_session((select id from sessions where offering_id = (select grp from ids) and starts_at < now() order by starts_at limit 1));
reset role;
select 'mom told' t, body from notifications where user_id = '40000000-0000-0000-0000-000000000004' and kind = 'schedule_changed';
select 'mom seats' t, status, count(*) from bookings where booked_by = '40000000-0000-0000-0000-000000000004' group by status;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'mom cannot cancel meetings (expect error)' t;
select cancel_session((select id from sessions where offering_id = (select grp from ids) and starts_at > now() and not cancelled order by starts_at limit 1));
reset role;

\echo '===== 3. Duration: Rana sets 60 min without approval; future meetings follow'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
update offerings set minutes = 60 where id = (select grp from ids);
select 'offer' t, minutes, review_status, pending_changes from offerings where id = (select grp from ids);
reset role;
select 'future meetings minutes' t, minutes, count(*) from sessions where offering_id = (select grp from ids) and starts_at > now() and not cancelled group by minutes;

\echo '===== 4. Walk-in enrollment at the institute (one with a Classi account by phone, one without), installments'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000007';
select 'walk-in no account' t, institute_enroll((select crs from ids), 'سليم خطيب', '052-999 8877', 'installments', true) is not null;
select 'walk-in with account' t, institute_enroll((select crs from ids), 'يوسف', '0501234567', 'cash', false) is not null;
select 'bad phone (expect error)' t;
select institute_enroll((select crs from ids), 'x', '123');
select 'roster' t, student_name, offline, pay_method, pay_status, installments_paid || '/' || installments_total inst from owner_bookings((select crs from ids));
select 'to collect' t, who, amount, pay_method, installments_paid || '/' || installments_total from owner_payments() where title like 'إنجليزي%';
select confirm_payment((select booking_id from owner_bookings((select crs from ids)) where student_name = 'سليم خطيب'), null, true);
select confirm_payment((select booking_id from owner_bookings((select crs from ids)) where student_name = 'سليم خطيب'), null, true);
select 'after 3/3' t, pay_status, installments_paid from bookings where offline_name = 'سليم خطيب';
select 'one more (expect error)' t;
select confirm_payment((select booking_id from owner_bookings((select crs from ids)) where student_name = 'سليم خطيب'), null, true);
reset role;
select 'mom told about enrollment' t, body from notifications where user_id = '40000000-0000-0000-0000-000000000004' and body like 'سجّلك%';
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'mom sees it' t, count(*) from bookings where offering_id = (select crs from ids) and booked_by = auth.uid();
reset role;

\echo '===== 5. Course teacher reports the meeting incl. the walk-in; cancelling a course meeting notifies'
update sessions set starts_at = now() - interval '1 hour' where id = (select id from sessions where offering_id = (select crs from ids) order by starts_at limit 1);
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
select 'reports' t, write_session_reports((select id from sessions where offering_id = (select crs from ids) order by starts_at limit 1), 'تدريب محادثة', null,
  (select jsonb_agg(jsonb_build_object('booking_id', booking_id, 'understanding', 4)) from session_students((select id from sessions where offering_id = (select crs from ids) order by starts_at limit 1))));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000007';
select 'cancel course meeting' t, cancel_session((select id from sessions where offering_id = (select crs from ids) and starts_at > now() order by starts_at limit 1), 'صيانة');
reset role;
select 'course notices' t, p.full_name, n.body from notifications n join profiles p on p.id = n.user_id where n.body like '%صيانة%' order by 2;

\echo '===== 6. Remove Rana from staff'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000007';
select 'removed (courses unassigned)' t, institute_remove_staff((select rana from ids));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000003';
select 'rana sees course roster (expect 0)' t, count(*) from owner_bookings((select crs from ids));
reset role;

\echo '===== 7. Vacation'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'vacation over his group (expect error)' t;
select teacher_vacation(current_date + 1, current_date + 20);
select 'vacation fri-sat' t, teacher_vacation(current_date + 40 + ((5 - extract(dow from current_date + 40)::int + 7) % 7), current_date + 41 + ((5 - extract(dow from current_date + 40)::int + 7) % 7), 'سفر');
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'book on vacation 18:00 (expect error)' t;
select create_booking((select priv from ids), null, ((current_date + 40 + ((5 - extract(dow from current_date + 40)::int + 7) % 7)) + time '18:00') at time zone 'Asia/Jerusalem');
reset role;
