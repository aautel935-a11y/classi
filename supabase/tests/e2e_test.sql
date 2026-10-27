\pset pager off
\pset footer off
-- Full launch scenario with three brand-new accounts, exactly as the site creates them:
-- phone sign-up (Supabase auth.users row) → profile → offers → admin approval → bookings → payment → cancel.
create temp table d as select
  (current_date + 7 + ((2 - extract(dow from current_date + 7)::int + 7) % 7))::date tue,   -- a Tuesday 1-2 weeks ahead
  '91000000-0000-0000-0000-000000000001'::uuid admin, '91000000-0000-0000-0000-000000000002'::uuid tch,
  '91000000-0000-0000-0000-000000000003'::uuid own, '91000000-0000-0000-0000-000000000004'::uuid mom;
grant select on d to authenticated, anon;
-- the platform starts empty of demo data, like the live site now
update teachers set moderation_hidden = true where user_id is null;
update institutes set moderation_hidden = true where owner_id is null;

\echo '================ STEP 1. Sign-up by phone (3 accounts + admin)'
insert into auth.users (id, phone, raw_user_meta_data) values
 ((select admin from d), '972509318800', '{"full_name":"مجد المدير"}'),
 ((select tch from d),   '972521112233', '{"full_name":"أحمد ياسين","role":"teacher","town":"باقة الغربية"}'),
 ((select own from d),   '972531112233', '{"full_name":"معهد الأفق","role":"institute","town":"باقة الغربية"}'),
 ((select mom from d),   '972541112233', '{"full_name":"سمر خطيب","role":"guardian","town":"باقة الغربية"}');
update profiles set roles = array['admin','guardian']::app_role[] where id = (select admin from d);
select 'profiles' t, full_name, phone, active_role from profiles where id in (select unnest(array[tch, own, mom]) from d) order by full_name;

\echo '================ STEP 2. Teacher: profile, hours (2 ranges), 15-min break, 45-min lesson 120 ₪, WhatsApp'
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000002';
insert into teachers (user_id, name, town, subject_id, bio, years, is_school_teacher, whatsapp)
values (auth.uid(), 'أحمد ياسين', 'باقة الغربية', (select id from subjects order by id limit 1), 'رياضيات للثانوي، شرح مبسّط', 6, true, '+972521112233');
update teachers set buffer_minutes = 15 where user_id = auth.uid();
select set_bit_phone('052-111 2233', false);
delete from availability where teacher_id = my_teacher_id();
insert into availability (teacher_id, weekday, start_time, end_time) values
 (my_teacher_id(), 2, '09:00', '12:00'), (my_teacher_id(), 2, '16:00', '20:00');
insert into offerings (type, teacher_id, title, subject_id, places, price, minutes, auto_confirm, allow_weekly)
values ('private', my_teacher_id(), 'رياضيات 5 وحدات، حصة فردية', (select id from subjects order by id limit 1), array['home','online']::place_kind[], 120, 45, false, true);
select 'offer after save' t, title, price, minutes, review_status from offerings where teacher_id = my_teacher_id();
reset role; reset request.jwt.claim.sub;
set role anon;
select 'visitor sees it before approval (expect 0)' t, count(*) from offerings where title = 'رياضيات 5 وحدات، حصة فردية';
reset role;

\echo '================ STEP 3. Institute: profile, room, course 900 ₪ in 3 installments, 2 seats, 8 meetings'
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000003';
insert into institutes (owner_id, name, town, bio) values (auth.uid(), 'معهد الأفق', 'باقة الغربية', 'دورات بجروت');
insert into rooms (institute_id, name) select id, 'قاعة 1' from institutes where owner_id = auth.uid();
select set_bit_phone('053-111 2233', true);
insert into offerings (type, institute_id, title, subject_id, places, price, seats, minutes, start_date, sessions_count, schedule_note)
select 'course', i.id, 'دورة بجروت إنجليزي', (select id from subjects order by id limit 1), array['center']::place_kind[], 900, 2, 90, (select tue from d), 8, 'الثلاثاء 17:00'
  from institutes i where i.owner_id = auth.uid();
insert into sessions (offering_id, seq, starts_at, minutes, room_id)
select o.id, g, ((select tue from d) + (g - 1) * 7 + time '17:00') at time zone 'Asia/Jerusalem', 90, (select id from rooms r where r.institute_id = o.institute_id limit 1)
  from offerings o, generate_series(1, 8) g where o.title = 'دورة بجروت إنجليزي';
select 'course after save' t, title, price, seats, review_status, (select count(*) from sessions s where s.offering_id = o.id) meetings from offerings o where title = 'دورة بجروت إنجليزي';
reset role;

\echo '================ STEP 4. Admin approves both (review queue)'
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000001';
select 'queue' t, kind, owner_name, title from admin_review_queue() order by kind, title;
select admin_review(kind, id, true) from admin_review_queue();
select 'queue after (expect 0)' t, count(*) from admin_review_queue();
reset role;
set role anon; reset request.jwt.claim.sub;
select 'visitor sees offers now' t, title from offerings where title in ('رياضيات 5 وحدات، حصة فردية', 'دورة بجروت إنجليزي') order by 2;
select 'visitor sees WhatsApp number' t, whatsapp from teachers where name = 'أحمد ياسين';
reset role;
select 'teacher + owner told' t, p.full_name, n.body from notifications n join profiles p on p.id = n.user_id where n.kind like 'review%' order by 2;

\echo '================ STEP 5. Parent: child, private lesson Tuesday 16:00 by Bit, course in 3 installments'
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000004';
insert into children (guardian_id, name, grade) values (auth.uid(), 'كريم', 'صف 11');
select 'private booking' t, create_booking((select id from offerings where title = 'رياضيات 5 وحدات، حصة فردية'), (select id from children where name = 'كريم'),
       ((select tue from d) + time '16:00') at time zone 'Asia/Jerusalem', null, 'bit', false, 'home') is not null ok;
select 'same slot again (expect error)' t;
select create_booking((select id from offerings where title = 'رياضيات 5 وحدات، حصة فردية'), null, ((select tue from d) + time '16:00') at time zone 'Asia/Jerusalem', null, 'bit', false, 'home');
select 'inside the 15-min break 16:50 (expect error)' t;
select create_booking((select id from offerings where title = 'رياضيات 5 وحدات، حصة فردية'), null, ((select tue from d) + time '16:50') at time zone 'Asia/Jerusalem', null, 'bit', false, 'home');
select 'course enrol' t, create_booking((select id from offerings where title = 'دورة بجروت إنجليزي'), (select id from children where name = 'كريم'), null, null, 'installments') is not null ok;
select 'my schedule' t, o.title, b.status, b.pay_method, b.pay_status, b.price, b.installments_total, to_char(b.starts_at at time zone 'Asia/Jerusalem', 'Dy HH24:MI') at_
  from bookings b join offerings o on o.id = b.offering_id where b.booked_by = auth.uid() order by o.type;
select 'Bit number visible to me' t, owner_name, bit_phone from my_pay_numbers();
reset role;
select 'teacher + owner told' t, p.full_name, n.kind, n.body from notifications n join profiles p on p.id = n.user_id
 where n.kind in ('booking_request','booking_new') order by 2;

\echo '================ STEP 6. Teacher accepts; parent reports the Bit transfer; teacher confirms'
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000002';
update teachers set whatsapp = whatsapp where user_id = auth.uid();  -- no-op
select respond_booking((select b.id from bookings b join offerings o on o.id = b.offering_id where o.title = 'رياضيات 5 وحدات، حصة فردية' and b.status = 'pending'), true);
reset role;
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000004';
select report_payment((select b.id from bookings b join offerings o on o.id = b.offering_id where o.title = 'رياضيات 5 وحدات، حصة فردية' and b.booked_by = auth.uid()));
reset role;
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000002';
select 'teacher money list' t, who, amount, pay_status from owner_payments();
select confirm_payment((select b.id from bookings b join offerings o on o.id = b.offering_id where o.title = 'رياضيات 5 وحدات، حصة فردية' and b.status = 'confirmed'));
reset role;
select 'messages so far' t, p.full_name, n.kind, n.body from notifications n join profiles p on p.id = n.user_id
 where n.kind in ('booking_answer','payment_reported','payment_answer') order by n.created_at;
select 'private booking now' t, status, pay_status from bookings b join offerings o on o.id = b.offering_id where o.title = 'رياضيات 5 وحدات، حصة فردية';

\echo '================ STEP 7. Institute: installment 1 of 3 received; parent reports installment 2'
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000003';
select 'roster' t, student_name, pay_method, installments_paid || '/' || installments_total inst from owner_bookings((select id from offerings where title = 'دورة بجروت إنجليزي'));
select confirm_payment((select booking_id from owner_bookings((select id from offerings where title = 'دورة بجروت إنجليزي')) limit 1));
reset role;
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000004';
select report_payment((select b.id from bookings b join offerings o on o.id = b.offering_id where o.title = 'دورة بجروت إنجليزي' and b.booked_by = auth.uid()));
reset role;
select 'installment messages' t, p.full_name, n.body from notifications n join profiles p on p.id = n.user_id
 where n.body like '%الدفعة%' order by n.created_at;
select 'seats' t, seats, seats_taken(id) taken from offerings where title = 'دورة بجروت إنجليزي';

\echo '================ STEP 8. Busy times before cancel (feeds the booking calendar)'
select 'busy' t, to_char(starts_at at time zone 'Asia/Jerusalem', 'HH24:MI') at_, minutes
  from teacher_busy((select id from teachers where name = 'أحمد ياسين'), ((select tue from d) + time '00:00') at time zone 'Asia/Jerusalem', ((select tue from d) + time '23:59') at time zone 'Asia/Jerusalem');
\o /tmp/claude-0/e2e_before.json
select json_build_object('day', (select tue from d), 'avail', (select json_agg(json_build_object('weekday', weekday, 'start_time', start_time, 'end_time', end_time)) from availability where teacher_id = (select id from teachers where name = 'أحمد ياسين')),
  'busy', (select coalesce(json_agg(json_build_object('starts_at', starts_at, 'minutes', minutes)), '[]') from teacher_busy((select id from teachers where name = 'أحمد ياسين'), ((select tue from d) + time '00:00') at time zone 'Asia/Jerusalem', ((select tue from d) + time '23:59') at time zone 'Asia/Jerusalem')),
  'wa', (select whatsapp from teachers where name = 'أحمد ياسين'),
  'title', 'رياضيات 5 وحدات، حصة فردية',
  'start', (select starts_at from bookings b join offerings o on o.id = b.offering_id where o.title = 'رياضيات 5 وحدات، حصة فردية'));
\o

\echo '================ STEP 9. Parent cancels the private lesson: slot frees, teacher told'
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000004';
select cancel_booking((select b.id from bookings b join offerings o on o.id = b.offering_id where o.title = 'رياضيات 5 وحدات، حصة فردية' and b.booked_by = auth.uid()));
reset role;
select 'after cancel' t, status from bookings b join offerings o on o.id = b.offering_id where o.title = 'رياضيات 5 وحدات، حصة فردية';
select 'teacher told' t, n.body from notifications n where n.user_id = (select tch from d) and n.kind = 'booking_cancelled';
select 'busy after cancel (expect none)' t, count(*) from teacher_busy((select id from teachers where name = 'أحمد ياسين'), ((select tue from d) + time '00:00') at time zone 'Asia/Jerusalem', ((select tue from d) + time '23:59') at time zone 'Asia/Jerusalem');
set role authenticated; set request.jwt.claim.sub = '91000000-0000-0000-0000-000000000004';
select 'book the freed 16:00 again' t, create_booking((select id from offerings where title = 'رياضيات 5 وحدات، حصة فردية'), (select id from children where name = 'كريم'),
       ((select tue from d) + time '16:00') at time zone 'Asia/Jerusalem', null, 'cash', false, 'home') is not null ok;
reset role;

\echo '================ STEP 10. Phone pushes / SMS that would go out (want_push, sms kinds)'
select 'outgoing' t, p.full_name, n.kind, n.want_push push, n.kind = any(sms_kinds()) sms
  from notifications n join profiles p on p.id = n.user_id where p.id in (select unnest(array[tch, own, mom]) from d) order by n.created_at;
