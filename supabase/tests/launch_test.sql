\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000001','admin@t','{"full_name":"المدير"}'),
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000007','owner@t','{"full_name":"صاحب المعهد"}');
update profiles set roles = array['admin','guardian']::app_role[] where id = '40000000-0000-0000-0000-000000000001';
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
update institutes set owner_id='40000000-0000-0000-0000-000000000007' where name='معهد المستقبل';
create temp table ids as select (select id from offerings where title='رياضيات بجروت 5 وحدات') priv,
  (select id from teachers where name='سامر مصاروة') samer, (select id from institutes where name='معهد المستقبل') inst;
grant select on ids to authenticated, anon;
delete from notifications;

\echo '===== 1. Subscriptions off: everyone visible. Admin turns them on: Samer (account, unpaid) disappears, demo teachers stay'
set role anon; reset request.jwt.claim.sub;
select 'anon sees samer offers (off)' t, count(*) from offerings where teacher_id = (select samer from ids);
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000001';
select admin_set_setting('subscriptions_required', 'true');
select admin_set_setting('platform_bit', '054-111 2222');
reset role;
set role anon; reset request.jwt.claim.sub;
select 'anon sees samer offers (on, unpaid)' t, count(*) from offerings where teacher_id = (select samer from ids);
select 'anon sees samer profile' t, count(*) from teachers where id = (select samer from ids);
select 'demo teachers still visible' t, count(*) > 5 from teachers;
select 'plans' t, name, months, price from plans order by sort;
reset role;

\echo '===== 2. Samer picks 3 months, reports the Bit transfer; admin activates'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'request' t, request_subscription('m3') is not null;
select 'platform bit' t, setting('platform_bit');
select report_subscription_payment((select id from subscriptions where status = 'pending'));
select 'report again (expect error)' t;
select request_subscription('m1');
reset role;
select 'admin told' t, body from notifications where user_id = '40000000-0000-0000-0000-000000000001';
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000001';
select 'admin list' t, owner_name, request_status, request_price from admin_subscriptions() where request_id is not null;
select admin_activate_subscription((select id from subscriptions where status = 'reported'), true);
select 'gift institute 2 months' t, admin_grant_subscription(null, (select inst from ids), 2, 'عرض الإطلاق') > now();
select admin_set_plan('y1', 950, true);
reset role;
select 'samer paid until (~3 months)' t, round(extract(epoch from paid_until((select samer from ids), null) - now()) / 86400) days;
select 'owner told' t, body from notifications where user_id in ('40000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000007') and kind = 'subscription';
set role anon; reset request.jwt.claim.sub;
select 'anon sees samer offers (paid)' t, count(*) > 0 from offerings where teacher_id = (select samer from ids);
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'teacher cannot activate (expect error)' t;
select admin_activate_subscription((select id from subscriptions limit 1), true);
reset role;

\echo '===== 3. Expiry warnings'
update subscriptions set ends_at = now() + interval '6 days 23 hours' where teacher_id = (select samer from ids);
select 'reminders' t, subscription_reminders();
select 'warn' t, body from notifications where user_id = '40000000-0000-0000-0000-000000000002' and body like '%ينتهي%';
select 'again same day (expect 0)' t, subscription_reminders();
update subscriptions set ends_at = now() + interval '90 days' where teacher_id = (select samer from ids);

\echo '===== 4. Ratings: only after a real lesson; one per family per teacher; teacher replies; rating recalculated'
insert into bookings (id, offering_id, booked_by, starts_at, minutes, status, mode) values
 ('60000000-0000-0000-0000-000000000001', (select priv from ids), '40000000-0000-0000-0000-000000000004', now() - interval '3 hours', 60, 'confirmed', 'home'),
 ('60000000-0000-0000-0000-000000000002', (select priv from ids), '40000000-0000-0000-0000-000000000004', now() + interval '3 days', 60, 'confirmed', 'home');
select 'prompt' t, review_prompts();
select 'mom asked' t, body, link like '/review?booking=%' ok from notifications where user_id = '40000000-0000-0000-0000-000000000004' and kind = 'review_prompt';
select 'prompt again (expect 0)' t, review_prompts();
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'future lesson (expect error)' t;
select leave_review('60000000-0000-0000-0000-000000000002', 5);
select leave_review('60000000-0000-0000-0000-000000000001', 4, 'شرح واضح وصبور') is not null;
select leave_review('60000000-0000-0000-0000-000000000001', 5, 'شرح واضح وصبور جداً') is not null;
select 'one review only' t, count(*) from reviews where user_id = auth.uid();
reset role;
select 'samer rating' t, rating, reviews_count from teachers where id = (select samer from ids);
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select reply_review((select id from reviews limit 1), 'شكراً، يوسف طالب مجتهد');
reset role;
set role anon; reset request.jwt.claim.sub;
select 'public sees' t, stars, body, author_name, reply from reviews;
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000001';
select admin_hide_review((select id from reviews limit 1), true);
reset role;
select 'after hide' t, rating, reviews_count from teachers where id = (select samer from ids);
set role anon; reset request.jwt.claim.sub;
select 'public after hide' t, count(*) from reviews;
reset role;

\echo '===== 5. Hide demo data for launch'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000001';
select 'hidden rows' t, admin_demo_visible(false);
reset role;
set role anon; reset request.jwt.claim.sub;
select 'visible teachers now' t, string_agg(name, '، ') from teachers;
select 'visible offers now' t, count(*) from offerings;
reset role;

\echo '===== 6. Mom deletes her account'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'wrong word (expect error)' t;
select delete_my_account('نعم');
select delete_my_account('احذف');
reset role;
select 'mom gone' t, (select count(*) from auth.users where id = '40000000-0000-0000-0000-000000000004') users,
       (select count(*) from profiles where id = '40000000-0000-0000-0000-000000000004') profiles,
       (select count(*) from bookings where booked_by = '40000000-0000-0000-0000-000000000004') bookings;

\echo '===== 7. Samer (teacher) deletes his account: offers hidden, profile emptied'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select delete_my_account('احذف');
reset role;
select 'samer row' t, user_id, verify, moderation_hidden, bio from teachers where id = (select samer from ids);
select 'samer offers active' t, count(*) filter (where active) from offerings where teacher_id = (select samer from ids);
