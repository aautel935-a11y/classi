\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000003','rana@t','{"full_name":"رنا"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}');
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
update teachers set user_id='40000000-0000-0000-0000-000000000003' where name='رنا أبو حسين';
insert into children (id, guardian_id, name) values ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000004','يوسف');
create temp table ids as select (select id from offerings where title='رياضيات بجروت 5 وحدات') priv,
  (select id from offerings where title='مجموعة أونلاين، تحضير الشفوي') grp,
  ((date_trunc('week', now() at time zone 'Asia/Jerusalem')::date + 14) + time '16:00') at time zone 'Asia/Jerusalem' as mon;
grant select on ids to authenticated;

\echo '===== 1. Samer turns on a free trial and a 10-lesson package; adds an intro video'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
update offerings set trial_price = 0, package_enabled = true, package_size = 10, package_price = 1500 where id = (select priv from ids);
update teachers set intro_video_url = 'https://youtu.be/abc123' where user_id = auth.uid();
reset role; select test_approve_all();
select 'saved' t, trial_price, package_enabled, package_size, package_price from offerings where id = (select priv from ids);

\echo '===== 2. Mom books a free trial for Yousef; a second trial is refused'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'trial available' t, trial_available((select priv from ids), '50000000-0000-0000-0000-000000000001');
select 'trial' t, (select price || ' / trial=' || is_trial from bookings where id = x) from create_trial_booking((select priv from ids), '50000000-0000-0000-0000-000000000001', (select mon from ids)) x;
select 'trial again (expect false)' t, trial_available((select priv from ids), '50000000-0000-0000-0000-000000000001');
select 'second trial (expect error)' t;
select create_trial_booking((select priv from ids), '50000000-0000-0000-0000-000000000001', (select mon from ids) + interval '1 day');
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'samer told' t, body from notifications where user_id = auth.uid();
reset role;

\echo '===== 3. Mom has a weekly slot, then buys the package: booked lessons move onto it'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
update offerings set allow_weekly = true where id = (select priv from ids);
reset role;
update offerings set allow_weekly = true where id = (select priv from ids);
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'weekly' t, create_weekly_booking((select priv from ids), '50000000-0000-0000-0000-000000000001', (select mon from ids) + interval '7 days') ->> 'created';
select 'buy' t, buy_package((select priv from ids), '50000000-0000-0000-0000-000000000001', 'bit') is not null;
select 'package' t, size, remaining, status from lesson_packages;
select 'lessons on package' t, count(*) filter (where package_id is not null) on_pkg, min(price) filter (where package_id is not null) each_price, count(*) filter (where is_trial) trial from bookings;
select 'buy again (expect error)' t;
select buy_package((select priv from ids), '50000000-0000-0000-0000-000000000001');
reset role;

\echo '===== 4. Two more single lessons use the last credits; cancel returns one'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select create_booking((select priv from ids), '50000000-0000-0000-0000-000000000001', (select mon from ids) + interval '2 days') is not null;
select create_booking((select priv from ids), '50000000-0000-0000-0000-000000000001', (select mon from ids) + interval '3 days') is not null;
select 'package now' t, remaining, status from lesson_packages;
select 'third extra lesson pays normally' t, (select price from bookings where id = x) from create_booking((select priv from ids), '50000000-0000-0000-0000-000000000001', (select mon from ids) + interval '4 days') x;
select cancel_booking((select id from bookings where package_id is not null order by starts_at desc limit 1));
select 'after cancel' t, remaining, status from lesson_packages;
select 'last-lesson notice' t, body from notifications where user_id = auth.uid() and body like '%آخر حصة%';
reset role;

\echo '===== 5. Group offer without packages refuses; teacher cancels the package'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'group (expect error)' t;
select buy_package((select grp from ids));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'owner list' t, student_name, size, remaining, status from owner_packages((select priv from ids));
select cancel_package((select id from lesson_packages limit 1));
select 'after cancel' t, status from lesson_packages;
select 'future lessons back to normal price' t, count(*) from bookings where package_id is null and price = 150 and starts_at > now();
reset role;
