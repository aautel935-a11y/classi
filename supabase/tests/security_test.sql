-- Security regression suite (audit 31/10/2026). Every check prints "PASS: …" or "FAIL: …"; run_all.sh fails on any FAIL.
-- Synthetic accounts only (ids 6000…); the seed's teachers and offers are fictional.
\pset pager off
\pset footer off
set client_min_messages = notice;

-- ---------- assertion helpers (run with the caller's role) ----------
create function public.t_ok(p_label text, p_sql text) returns void language plpgsql as $$
begin execute p_sql; raise notice 'PASS: %', p_label;
exception when others then raise notice 'FAIL: % -> %', p_label, sqlerrm; end $$;
create function public.t_err(p_label text, p_sql text) returns void language plpgsql as $$
begin execute p_sql; raise notice 'FAIL: % -> it was allowed', p_label;
exception when others then raise notice 'PASS: % (refused: %)', p_label, left(sqlerrm, 90); end $$;
create function public.t_is(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
declare v text;
begin execute p_sql into v;
  if v is not distinct from p_expect then raise notice 'PASS: % = %', p_label, coalesce(v, 'null');
  else raise notice 'FAIL: % -> got %, expected %', p_label, coalesce(v, 'null'), coalesce(p_expect, 'null'); end if;
exception when others then raise notice 'FAIL: % -> %', p_label, sqlerrm; end $$;
grant execute on function public.t_ok(text,text), public.t_err(text,text), public.t_is(text,text,text) to anon, authenticated;

-- ---------- synthetic people ----------
insert into auth.users (id, email, raw_user_meta_data) values
 ('60000000-0000-0000-0000-00000000000a','attacker@t','{"full_name":"منتحل","role":"institute"}'),
 ('60000000-0000-0000-0000-00000000000b','samer@t','{"full_name":"سامر مصاروة"}'),
 ('60000000-0000-0000-0000-00000000000c','owner@t','{"full_name":"صاحب معهد المستقبل"}'),
 ('60000000-0000-0000-0000-00000000000d','mom@t','{"full_name":"أم يوسف"}'),
 ('60000000-0000-0000-0000-00000000000e','dad@t','{"full_name":"أبو سليم"}'),
 ('60000000-0000-0000-0000-00000000000f','noor@t','{"full_name":"نور كبها"}');
update teachers set user_id='60000000-0000-0000-0000-00000000000b' where name='سامر مصاروة';
update teachers set user_id='60000000-0000-0000-0000-00000000000f' where name='نور كبها';
update institutes set owner_id='60000000-0000-0000-0000-00000000000c' where name='معهد المستقبل';
update profiles set phone='+972501111111', sms_ok=true where id='60000000-0000-0000-0000-00000000000b';
update profiles set phone='+972504444444' where id='60000000-0000-0000-0000-00000000000d';
update profiles set status='suspended', suspended_until=now()+interval '7 days' where id='60000000-0000-0000-0000-00000000000f';
insert into children (guardian_id, name) values ('60000000-0000-0000-0000-00000000000d', 'يوسف');
create temp table ids as select
  (select id from teachers where name='سامر مصاروة') samer,
  (select id from teachers where name='نور كبها') noor,
  (select id from institutes where name='معهد المستقبل') inst,
  (select id from offerings where title='رياضيات بجروت 5 وحدات') priv,
  (select id from offerings where title='مجموعة تقوية رياضيات، صف عاشر') grp,
  (select id from offerings where title='الدوال من الصفر، 12 درساً مصوّراً') rec,
  (select id from offerings where title='إنجليزي محادثة للإعدادي') crs,
  (select id from offerings where title='رياضيات 4 وحدات، مجموعة صغيرة') noor_grp,
  (select r.id from rooms r join institutes i on i.id=r.institute_id where i.name='مركز النخبة للتعليم' limit 1) other_room,
  (select id from children where name='يوسف') kid;
grant select on ids to anon, authenticated;
insert into app_secrets values ('dispatch_secret','s3cret') on conflict (key) do update set value = excluded.value;
delete from notifications;

\echo '===== SEC-01 internal functions are not callable by app users'
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000a';
select t_err('notify_admins (phishing to admins)', $$select notify_admins('اضغط هنا','https://evil.example')$$);
select t_err('report_target (child name for any booking)', $$select report_target((select id from bookings limit 1))$$);
select t_err('review_prompts', $$select review_prompts()$$);
select t_err('subscription_reminders', $$select subscription_reminders()$$);
select t_err('recount_rating', $$select recount_rating(null, null)$$);
select t_err('waitlist_notify_next', $$select waitlist_notify_next((select priv from ids))$$);
select t_err('package_apply_existing', $$select package_apply_existing(gen_random_uuid())$$);
select t_err('waitlist_position', $$select waitlist_position(gen_random_uuid())$$);
select t_err('sms_allow', $$select sms_allow(auth.uid())$$);
select t_ok('the app''s own calls still work (my_header_counts)', $$select my_header_counts()$$);
reset role; reset request.jwt.claim.sub;
set role anon;
select t_err('anon: owner_bookings', $$select * from owner_bookings()$$);
select t_ok('anon: public setting', $$select setting('support_whatsapp')$$);
select t_ok('anon: seats_overview', $$select count(*) from seats_overview()$$);
reset role;
select t_is('trigger functions callable by authenticated', $$select count(*)::text from pg_proc p where p.pronamespace='public'::regnamespace
   and p.prorettype='trigger'::regtype and has_function_privilege('authenticated', p.oid, 'execute')$$, '0');
select t_is('functions callable by anon (exact list)', $$select string_agg(proname, ',' order by proname) from pg_proc p
   where p.pronamespace='public'::regnamespace and has_function_privilege('anon', p.oid, 'execute') and proname not like 't\_%' and proname <> 'test_day'$$,
  'claim_otp,claim_push,drop_push_subscriptions,health_ping,is_active_user,is_admin,is_conversation_member,is_conversation_reported,is_offering_owner,is_offering_staff,log_sms,my_teacher_id,offering_owner_verified,owner_has_access,seats_overview,setting,teacher_buffer,teacher_busy');

\echo '===== SEC-02 institute staff needs consent; no SMS from staff changes'
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000a';
select t_ok('attacker creates an (unverified) institute', $$insert into institutes (owner_id, name, town) values (auth.uid(), 'معهد وهمي', 'باقة الغربية')$$);
select t_err('unverified institute adds any teacher to its staff', $$insert into institute_teachers (institute_id, teacher_id)
   select id, (select samer from ids) from institutes where owner_id = auth.uid()$$);
select t_err('attacker removes a teacher it never had', $$select institute_remove_staff((select samer from ids))$$);
reset role;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000c';
select t_err('owner cannot add staff as already accepted', $$insert into institute_teachers (institute_id, teacher_id, status) values ((select inst from ids), (select samer from ids), 'accepted')$$);
select t_ok('verified institute invites Samer', $$insert into institute_teachers (institute_id, teacher_id) values ((select inst from ids), (select samer from ids))$$);
select t_err('SEC-04: invited (not accepted) teacher as course teacher', $$update offerings set course_teacher_id = (select samer from ids) where id = (select crs from ids)$$);
select t_err('owner accepts the invitation on the teacher''s behalf', $$update institute_teachers set status='accepted' where teacher_id=(select samer from ids)$$);
reset role;
select t_is('Samer was told in the app (not SMS)', $$select string_agg(kind || ':' || (kind = any(sms_kinds()))::text, ',') from notifications
   where user_id='60000000-0000-0000-0000-00000000000b'$$, 'staff_invite:false');
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000b';
select t_is('Samer sees the invitation', $$select count(*)::text from my_staff_invites()$$, '1');
select t_ok('Samer accepts', $$select answer_staff_invite((select inst from ids), true)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000c';
select t_ok('accepted teacher can now be the course teacher', $$update offerings set course_teacher_id = (select samer from ids) where id = (select crs from ids)$$);
select t_ok('owner removes Samer', $$select institute_remove_staff((select samer from ids))$$);
reset role;
select t_is('removal is not an SMS kind', $$select bool_or(kind = any(sms_kinds()))::text from notifications where user_id='60000000-0000-0000-0000-00000000000b'$$, 'false');
insert into app_settings (key, value) values ('staff_invites_per_day', '1') on conflict (key) do update set value = excluded.value;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000c';
select t_ok('invite #1 today', $$insert into institute_teachers (institute_id, teacher_id) values ((select inst from ids), (select samer from ids))$$);
select t_err('invites above the daily cap', $$insert into institute_teachers (institute_id, teacher_id) select (select inst from ids), id from teachers where name='يوسف عازم'$$);
reset role;
delete from app_settings where key = 'staff_invites_per_day';

\echo '===== SEC-04 nobody can block a teacher''s calendar with a fake course'
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000a';
select t_err('attacker names Samer as its course teacher', $$insert into offerings (type, institute_id, course_teacher_id, title, places, price, seats, minutes)
   select 'course', i.id, (select samer from ids), 'دورة وهمية', array['center']::place_kind[], 1, 1, 90 from institutes i where owner_id = auth.uid()$$);
reset role;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000c';
select t_err('a 600-minute meeting', $$insert into sessions (offering_id, seq, starts_at, minutes) values ((select crs from ids), 99, now() + interval '9 days', 600)$$);
select t_err('a negative-length meeting', $$insert into sessions (offering_id, seq, starts_at, minutes) values ((select crs from ids), 98, now() + interval '9 days', -60)$$);
select t_err('SEC-33: another institute''s room', $$insert into sessions (offering_id, seq, starts_at, minutes, room_id) values ((select crs from ids), 97, now() + interval '9 days', 90, (select other_room from ids))$$);
reset role;

\echo '===== SEC-03 / SEC-10 phone numbers stay private; walk-ins are linked by the phone''s owner'
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000c';
select t_ok('walk-in with a registered parent''s phone', $$select institute_enroll((select crs from ids), 'يوسف', '050-444 4444', 'cash', false)$$);
select t_ok('walk-in with an unknown phone', $$select institute_enroll((select crs from ids), 'غريب', '052-999 0000', 'cash', false)$$);
select t_is('booking is not linked automatically', $$select count(*)::text from bookings where offline_name = 'يوسف' and booked_by is not null$$, '0');
select t_is('can_link says the same for both numbers (no lookup)', $$select string_agg(can_link::text, ',' order by student_name) from owner_bookings((select crs from ids))
   where student_name in ('يوسف','غريب')$$, 'true,true');
select t_ok('institute asks to link (registered number)', $$select institute_link_booking((select booking_id from owner_bookings((select crs from ids)) where student_name='يوسف'))$$);
select t_ok('institute asks to link (unknown number): same answer', $$select institute_link_booking((select booking_id from owner_bookings((select crs from ids)) where student_name='غريب'))$$);
reset role;
select t_is('parent got an invitation (not a booking)', $$select string_agg(kind, ',') from notifications where user_id='60000000-0000-0000-0000-00000000000d'$$, 'link_request');
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000e';
select t_err('someone else cannot accept it', $$select accept_booking_link((select id from bookings where offline_name='يوسف'))$$);
reset role;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000d';
select t_is('parent sees the pending link', $$select count(*)::text from my_link_requests()$$, '1');
select t_ok('parent accepts', $$select accept_booking_link((select booking_id from my_link_requests() limit 1))$$);
select t_is('now it is the parent''s booking', $$select count(*)::text from bookings where booked_by = auth.uid() and offline_name='يوسف'$$, '1');
reset role;
select send_sms_hook('{"user":{"phone":"","phone_change":"972529998877","email":"x@t"},"sms":{"otp":"654321","sms_type":"phone_change"}}') is not null queued;
select t_is('phone-change code is queued for SMS but never emailed', $$select count(*)::text || ':' || count(email)::text from otp_outbox where phone like '%529998877'$$, '1:0');

\echo '===== SEC-08 sign-in codes: Israeli mobiles only, rate-limited'
select t_is('foreign number refused', $$select send_sms_hook('{"user":{"phone":"447700900000"},"sms":{"otp":"123456"}}') -> 'error' ->> 'http_code'$$, '400');
insert into otp_requests (phone) select '972521112233' from generate_series(1, 5);
select t_is('6th code within an hour refused', $$select send_sms_hook('{"user":{"phone":"972521112233"},"sms":{"otp":"123456"}}') -> 'error' ->> 'http_code'$$, '429');

\echo '===== SEC-02/07 SMS budget per person per day'
delete from notifications;
insert into notifications (user_id, kind, body) select '60000000-0000-0000-0000-00000000000b', 'schedule_changed', 'تغيير ' || g from generate_series(1, 10) g;
select t_is('10 SMS-type notifications -> at most 6 SMS', $$select count(*)::text from jsonb_array_elements(claim_push('s3cret')->'items') e where e->>'phone' is not null$$, '6');

\echo '===== SEC-06 notifications can only be marked read'
insert into notifications (user_id, kind, body) values ('60000000-0000-0000-0000-00000000000d', 'message', 'رسالة');
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000d';
select t_err('rewrite own notification (kind/body/push)', $$update notifications set kind='admin_note', body='نص حر', pushed_at=null where user_id = auth.uid()$$);
select t_ok('mark own notifications read', $$update notifications set read_at = now() where user_id = auth.uid()$$);
reset role;

\echo '===== SEC-17 / 27 / 22 booking rules'
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000d';
select t_err('private lesson outside the teacher''s hours (Saturday 03:00)', $$select create_booking((select priv from ids), null, (test_day(6) + time '03:00') at time zone 'Asia/Jerusalem', null, 'bit', false, 'online')$$);
select t_err('unknown payment method', $$select create_booking((select priv from ids), null, (test_day(1) + time '15:00') at time zone 'Asia/Jerusalem', null, 'free money', false, 'online')$$);
select t_err('"from the package" without a package', $$select create_booking((select priv from ids), null, (test_day(1) + time '15:00') at time zone 'Asia/Jerusalem', null, 'package', false, 'online')$$);
select t_ok('normal booking inside hours', $$select create_booking((select priv from ids), null, (test_day(1) + time '15:00') at time zone 'Asia/Jerusalem', null, 'bit', false, 'online')$$);
reset role;
insert into app_settings (key, value) values ('max_open_bookings_per_offer', '2') on conflict (key) do update set value = excluded.value;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000d';
select t_ok('2nd open booking', $$select create_booking((select priv from ids), null, (test_day(2) + time '15:00') at time zone 'Asia/Jerusalem', null, 'bit', false, 'online')$$);
select t_err('3rd open booking above the cap', $$select create_booking((select priv from ids), null, (test_day(3) + time '15:00') at time zone 'Asia/Jerusalem', null, 'bit', false, 'online')$$);
select t_ok('group seat', $$select create_booking((select grp from ids), null, null, (select id from sessions where offering_id=(select grp from ids) and starts_at > now() order by starts_at limit 1), 'cash')$$);
select t_err('same student, same meeting, again', $$select create_booking((select grp from ids), null, null, (select id from sessions where offering_id=(select grp from ids) and starts_at > now() order by starts_at limit 1), 'cash')$$);
reset role;
delete from app_settings where key = 'max_open_bookings_per_offer';
-- review finding F1: a weekly series paid "from the package" keeps working after the package's lessons run out
update offerings set package_enabled = true, package_size = 5, package_price = 600, allow_weekly = true where id = (select priv from ids);
select test_approve_all();
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000e';
select t_ok('buy a 5-lesson package', $$select buy_package((select priv from ids), null)$$);
select t_is('weekly series of 8 paid from the package', $$select create_weekly_booking((select priv from ids), null, (test_day(4, 3) + time '17:00') at time zone 'Asia/Jerusalem', null, 'package') ->> 'created'$$, '8');
select t_is('5 weeks on the package, the rest paid normally', $$select count(*) filter (where package_id is not null)::text || '+' || count(*) filter (where package_id is null and pay_method = 'cash')::text
   from bookings where booked_by = auth.uid() and series_id is not null$$, '5+3');
reset role;

\echo '===== SEC-07 a booking withdrawn right away does not text the teacher'
delete from notifications;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000d';
select t_ok('cancel the group seat at once', $$select cancel_booking((select id from bookings where booked_by = auth.uid() and session_id is not null and status='confirmed' limit 1))$$);
reset role;
select t_is('teacher notification kind', $$select string_agg(kind || ':' || (kind = any(sms_kinds()))::text, ',') from notifications where user_id='60000000-0000-0000-0000-00000000000b'$$, 'booking_withdrawn:false');

\echo '===== SEC-14 / SEC-15 no cancelling or reviewing around a lesson that has not been taught'
insert into sessions (offering_id, seq, starts_at, minutes) values ((select grp from ids), 900, now() - interval '3 days', 90);
insert into bookings (offering_id, session_id, booked_by, minutes, status, pay_method)
  values ((select grp from ids), (select id from sessions where seq = 900 and offering_id = (select grp from ids)), '60000000-0000-0000-0000-00000000000e', 90, 'confirmed', 'cash');
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000e';
select t_err('cancel a meeting that already happened', $$select cancel_booking((select id from bookings where booked_by = auth.uid() and session_id is not null))$$);
reset role;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000d';
select t_err('review before the lesson took place', $$select leave_review((select id from bookings where booked_by = auth.uid() and starts_at is not null and status <> 'cancelled' order by starts_at limit 1), 1, 'سيئ')$$);
reset role;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000e';
select t_ok('review after the meeting', $$select leave_review((select id from bookings where booked_by = auth.uid() and session_id is not null), 5, 'ممتاز')$$);
reset role;
update bookings set status='cancelled' where booked_by='60000000-0000-0000-0000-00000000000e' and session_id is not null;
select t_is('review of a cancelled booking is hidden', $$select hidden::text from reviews where user_id='60000000-0000-0000-0000-00000000000e'$$, 'true');

\echo '===== SEC-16 / SEC-24 content and payment numbers'
insert into offering_links (offering_id, url) values ((select rec from ids), 'https://example.com/course') on conflict do nothing;
insert into pay_numbers (teacher_id, bit_phone) values ((select samer from ids), '+972501111111') on conflict do nothing;
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000e';
select t_ok('book the recorded course (unpaid)', $$select create_booking((select rec from ids), null, null, null, 'bit')$$);
select t_is('content link before payment', $$select count(*)::text from offering_links where offering_id = (select rec from ids)$$, '0');
select t_ok('cancel it', $$select cancel_booking((select id from bookings where booked_by = auth.uid() and offering_id = (select rec from ids)))$$);
select t_is('Bit number after cancelling', $$select count(*)::text from my_pay_numbers() where offering_id = (select rec from ids)$$, '0');
reset role;

\echo '===== SEC-13 a suspended teacher cannot change anything'
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000f';
select t_err('suspended: hide own offer', $$update offerings set active = false where id = (select noor_grp from ids)$$);
select t_err('suspended: change hours', $$delete from availability where teacher_id = (select noor from ids)$$);
reset role;

\echo '===== SEC-05 deleting never erases bookings, payments or reviews'
select count(*) as priv_bookings from bookings where offering_id = (select priv from ids) \gset
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000b';
select t_ok('Samer tries to delete his booked private offer', $$delete from offerings where id = (select priv from ids)$$);
select t_is('offer and its bookings are still there', $$select (select count(*) from offerings where id = (select priv from ids))::text || '/' ||
   (select count(*) from bookings where offering_id = (select priv from ids))::text$$, '1/' || :'priv_bookings');
select t_ok('Samer tries to delete a booked meeting', $$delete from sessions where id = (select session_id from bookings where offering_id = (select grp from ids) and session_id is not null limit 1)$$);
select t_is('the meeting is still there', $$select count(*)::text from sessions s join bookings b on b.session_id = s.id where s.offering_id = (select grp from ids)$$, '2');
reset role;
select t_err('even the database owner cannot cascade-delete booked offers', $$delete from offerings where id = (select priv from ids)$$);

\echo '===== SEC-18 deleting an account keeps the other side''s history'
update bookings set starts_at = now() - interval '2 days' where id = (select id from bookings where booked_by='60000000-0000-0000-0000-00000000000d' and offering_id=(select priv from ids) order by starts_at limit 1);
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000d';
select t_ok('parent deletes the account', $$select delete_my_account('احذف')$$);
reset role;
select t_is('past lesson stays with the teacher, anonymised', $$select status || ':' || offline_name || ':' || (booked_by is null)::text from bookings
   where offering_id=(select priv from ids) and starts_at < now()$$, 'confirmed:حساب محذوف:true');
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000c';
select t_ok('institute owner who rescheduled can still delete the account', $$select reschedule_session((select id from sessions where offering_id=(select crs from ids) and starts_at > now() order by starts_at limit 1), now() + interval '20 days', null)$$);
select t_ok('…and delete it', $$select delete_my_account('احذف')$$);
reset role;

\echo '===== SEC-19 / SEC-20 anonymous visitors see no internal columns'
set role anon;
select t_err('anon reads review booking/user/child ids', $$select booking_id, user_id, child_id from reviews limit 1$$);
select t_ok('anon reads public review fields', $$select id, stars, body, author_name, created_at from reviews limit 1$$);
select t_err('anon reads unapproved edits and moderation notes', $$select pending_changes, review_note from teachers limit 1$$);
select t_ok('anon reads the public teacher card', $$select id, name, town, rating, reviews_count, photo_url from teachers limit 1$$);
select t_ok('anon reads the catalogue', $$select id, title, type, price from offerings where active limit 1$$);
reset role;

\echo '===== SEC-28 photo links must be Classi storage'
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000e';
select t_err('tracking-pixel avatar', $$update profiles set avatar_url = 'https://evil.example/p.png' where id = auth.uid()$$);
reset role;

\echo '===== SEC-31 attendance only for bookings of that offer'
set role authenticated; set request.jwt.claim.sub='60000000-0000-0000-0000-00000000000b';
select t_err('attendance on a foreign booking', $$insert into attendance (session_id, booking_id, present)
   values ((select id from sessions where offering_id=(select grp from ids) order by starts_at desc limit 1), (select id from bookings where offering_id <> (select grp from ids) limit 1), true)$$);
reset role;
