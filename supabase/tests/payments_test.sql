\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000005','dad@t','{"full_name":"أبو آدم"}');
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
create temp table ids as select (select id from offerings where title='رياضيات بجروت 5 وحدات') priv,
  ((date_trunc('week', now() at time zone 'Asia/Jerusalem')::date + 14) + time '16:00') at time zone 'Asia/Jerusalem' as mon;
grant select on ids to authenticated;
update offerings set auto_confirm = true, trial_price = 0, package_enabled = true, package_size = 5, package_price = 650 where id = (select priv from ids);

\echo '===== 1. Samer adds his Bit number'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'bit' t, set_bit_phone('052-123 4567');
select 'bad number (expect error)' t;
select set_bit_phone('123');
reset role;

\echo '===== 2. Mom: trial (free), then a Bit lesson, then a cash lesson'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select create_trial_booking((select priv from ids), null, (select mon from ids)) is not null;
select create_booking((select priv from ids), null, (select mon from ids) + interval '1 day', null, 'bit') is not null;
select create_booking((select priv from ids), null, (select mon from ids) + interval '2 days', null, 'cash') is not null;
select 'mom lessons' t, pay_method, price, pay_status from bookings where booked_by = auth.uid() order by starts_at;
select 'bit number shown to mom' t, owner_name, bit_phone from my_pay_numbers();
select 'mom reports transfer' t, report_payment((select id from bookings where pay_method = 'bit' and not is_trial and booked_by = auth.uid()));
select 'report twice (expect error)' t;
select report_payment((select id from bookings where pay_method = 'bit' and not is_trial and booked_by = auth.uid()));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select 'dad sees no numbers' t, count(*) from my_pay_numbers();
select 'dad cannot confirm (expect error)' t;
select confirm_payment((select id from bookings where pay_method = 'bit' and not is_trial limit 1));
reset role;

\echo '===== 3. Samer: payments list, confirms Bit, marks cash received'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'told' t, body from notifications where user_id = auth.uid() and kind = 'payment_reported';
select 'to collect' t, kind, who, amount, pay_method, pay_status from owner_payments();
select confirm_payment((select id from bookings where pay_method = 'bit' and not is_trial), null, true);
select confirm_payment((select id from bookings where pay_method = 'cash'), null, true);
select 'confirm free trial (expect error)' t;
select confirm_payment((select id from bookings where is_trial), null, true);
select 'summary' t, * from owner_money_summary();
select 'roster' t, student_name, price, pay_status from owner_bookings((select priv from ids)) order by starts_at;
reset role;
select 'mom told' t, body from notifications where user_id = '40000000-0000-0000-0000-000000000004' and kind = 'payment_answer';

\echo '===== 4. Package: bought, reported, teacher says not received, then received; lessons inside are "package"'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000005';
select buy_package((select priv from ids), null, 'bit') is not null;
select create_booking((select priv from ids), null, (select mon from ids) + interval '3 days', null, 'package') is not null;
select 'dad lesson' t, price, pay_status from bookings where booked_by = auth.uid();
select report_payment(null, (select id from lesson_packages where user_id = auth.uid()));
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select confirm_payment(null, (select id from lesson_packages limit 1), false);
select 'pkg after no' t, pay_status from owner_packages((select priv from ids));
reset role;
select 'dad told' t, body from notifications where user_id = '40000000-0000-0000-0000-000000000005' and kind = 'payment_answer';
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select confirm_payment(null, (select id from lesson_packages limit 1), true);
select 'pkg after yes' t, pay_status from owner_packages((select priv from ids));
select 'calendar has pay' t, who, pay_status, price from my_teacher_calendar(now(), now() + interval '30 days') where kind = 'booking' order by starts_at;
reset role;
