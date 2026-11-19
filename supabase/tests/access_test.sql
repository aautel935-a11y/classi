-- v3 business access: launch date, 30-day trial, repeat-trial guard, grace, exemption, discounts, plans, reminders, report.
-- Every check prints PASS:/FAIL:. Synthetic accounts only (ids 7200…). Run: sh supabase/tests/run.sh access_test
\pset pager off
\pset footer off
set client_min_messages = notice;

insert into auth.users (id, email, phone, raw_user_meta_data) values
 ('72000000-0000-0000-0000-00000000000a','samer@t',  '972501110001','{"full_name":"سامر مصاروة"}'),
 ('72000000-0000-0000-0000-00000000000b','owner@t',  '972501110002','{"full_name":"صاحب معهد المستقبل"}'),
 ('72000000-0000-0000-0000-00000000000c','admin@t',  '972501110003','{"full_name":"مدير"}'),
 ('72000000-0000-0000-0000-00000000000d','new@t',    '972501110004','{"full_name":"حرفي جديد"}'),
 ('72000000-0000-0000-0000-00000000000e','again@t',  '972501110004','{"full_name":"نفس الهاتف بحساب آخر"}'),
 ('72000000-0000-0000-0000-00000000000f','mom@t',    '972501110005','{"full_name":"أم يوسف"}');
update profiles set phone = '+' || u.phone from auth.users u where u.id = profiles.id and u.id::text like '72000000%';
update profiles set roles = array['admin']::app_role[] where id = '72000000-0000-0000-0000-00000000000c';
update teachers set user_id='72000000-0000-0000-0000-00000000000a' where name='سامر مصاروة';
update institutes set owner_id='72000000-0000-0000-0000-00000000000b' where name='معهد المستقبل';
create temp table ids as select (select id from teachers where name='سامر مصاروة') samer, (select id from institutes where name='معهد المستقبل') inst;
grant select on ids to authenticated, anon;

\echo '===== before launch: nothing changes'
select t_is('switch is off', $$select setting('subscriptions_required')$$, 'false');
select t_is('no launch date: prelaunch', $$select state from business_access_state((select samer from ids), null)$$, 'prelaunch');
select t_is('owner_has_access true (switch off)', $$select owner_has_access((select samer from ids), null)::text$$, 'true');
select t_is('no trial rows before launch', $$select count(*)::text from business_trials$$, '0');

\echo '===== admin settings'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000a';
select t_err('non-admin cannot set launch_at', $$select admin_set_setting('launch_at', '2026-01-01')$$);
select t_err('non-admin cannot extend a trial', $$select admin_extend_trial((select samer from ids), null, 10, 'هدية')$$);
select t_err('non-admin cannot read the access list', $$select admin_access_report(current_date - 1, current_date)$$);
select t_is('non-admin gets an empty access list', $$select count(*)::text from admin_business_access()$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_err('trial_days above 90 refused', $$select admin_set_setting('trial_days', '120')$$);
select t_err('bad launch date refused', $$select admin_set_setting('launch_at', '20/11/2026')$$);
select t_ok('launch 10 days ago', $$select admin_set_setting('launch_at', to_char(current_date - 10, 'YYYY-MM-DD'))$$);
reset role;
select t_is('existing teacher: trial from launch', $$select state || ':' || days_left from business_access_state((select samer from ids), null)$$, 'trial:20');
select t_is('existing institute: trial from launch', $$select state from business_access_state(null, (select inst from ids))$$, 'trial');

\echo '===== a new business after launch gets its own 30 days; a repeat gets none'
insert into teachers (name, town, verify, user_id) values ('حرفي جديد', 'باقة', 'verified', '72000000-0000-0000-0000-00000000000d');
select t_is('new teacher trial row', $$select count(*)::text from business_trials where owner_id = '72000000-0000-0000-0000-00000000000d'$$, '1');
select t_is('new teacher: 30 days', $$select state || ':' || days_left from business_access_state((select id from teachers where name='حرفي جديد'), null)$$, 'trial:30');
select t_is('phone stored only as a hash', $$select (phone_hash ~ '^[0-9a-f]{64}$' and phone_hash not like '%501110004%')::text from business_trials limit 1$$, 'true');
insert into institutes (name, town, verify, owner_id) values ('معهد الحرفي', 'باقة', 'verified', '72000000-0000-0000-0000-00000000000d');
select t_is('same owner, second business: repeat, no trial', $$select state from business_access_state(null, (select id from institutes where name='معهد الحرفي'))$$, 'expired');
insert into teachers (name, town, verify, user_id) values ('نفس الهاتف', 'باقة', 'verified', '72000000-0000-0000-0000-00000000000e');
select t_is('same phone, other account: repeat', $$select (repeat_of is not null)::text from business_trials where owner_id = '72000000-0000-0000-0000-00000000000e'$$, 'true');
select t_is('repeat trial is expired', $$select state from business_access_state((select id from teachers where name='نفس الهاتف'), null)$$, 'expired');
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_err('launch date locked once trials started', $$select admin_set_setting('launch_at', to_char(current_date, 'YYYY-MM-DD'))$$);
select t_is('admin sees the repeat flag', $$select repeat_trial::text from admin_business_access() where name = 'نفس الهاتف'$$, 'true');
select t_err('extension needs a reason', $$select admin_extend_trial((select id from teachers where name='نفس الهاتف'), null, 14, '')$$);
select t_ok('admin gives the repeat 14 days after checking', $$select admin_extend_trial((select id from teachers where name='نفس الهاتف'), null, 14, 'تحقق: شخص مختلف')$$);
select t_is('now in trial', $$select state from admin_business_access() where name = 'نفس الهاتف'$$, 'trial');
reset role;

\echo '===== switch on: grace, expiry, renewal; data kept'
update app_settings set value = 'true' where key = 'subscriptions_required';
update business_trials set ends_at = now() - interval '3 days' where owner_id = '72000000-0000-0000-0000-00000000000d' and teacher_id is not null;
select t_is('3 days after trial: grace', $$select state || ':' || days_left from business_access_state((select id from teachers where name='حرفي جديد'), null)$$, 'grace:4');
select t_is('grace stays visible', $$select owner_has_access((select id from teachers where name='حرفي جديد'), null)::text$$, 'true');
update business_trials set ends_at = now() - interval '8 days' where owner_id = '72000000-0000-0000-0000-00000000000d' and teacher_id is not null;
select t_is('after grace: expired', $$select state from business_access_state((select id from teachers where name='حرفي جديد'), null)$$, 'expired');
select t_is('expired is hidden', $$select owner_has_access((select id from teachers where name='حرفي جديد'), null)::text$$, 'false');
set role anon; set request.jwt.claim.sub='';
select t_is('customers do not see the expired teacher', $$select count(*)::text from teachers where name='حرفي جديد'$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000d';
select t_is('owner still sees own profile (data kept)', $$select count(*)::text from teachers where name='حرفي جديد'$$, '1');
select t_is('owner sees own state', $$select state from my_access_state() where kind = 'teacher'$$, 'expired');
select t_ok('owner requests the monthly plan', $$select request_subscription('m1')$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_err('discount above list price refused', $$select admin_discount_request((select id from subscriptions where status='pending' and teacher_id=(select id from teachers where name='حرفي جديد')), 500, 'خطأ')$$);
select t_err('discount needs a reason', $$select admin_discount_request((select id from subscriptions where status='pending' and teacher_id=(select id from teachers where name='حرفي جديد')), 120, '')$$);
select t_ok('discount to 120', $$select admin_discount_request((select id from subscriptions where status='pending' and teacher_id=(select id from teachers where name='حرفي جديد')), 120, 'عرض الإطلاق')$$);
select t_is('list price kept', $$select list_price || '/' || price from subscriptions where teacher_id=(select id from teachers where name='حرفي جديد') and status='pending'$$, '170/120');
select t_ok('admin activates after the transfer arrived', $$select admin_activate_subscription((select id from subscriptions where status='pending' and teacher_id=(select id from teachers where name='حرفي جديد')), true, 'وصل التحويل')$$);
reset role;
select t_is('active and visible again', $$select state || ':' || owner_has_access((select id from teachers where name='حرفي جديد'), null)::text from business_access_state((select id from teachers where name='حرفي جديد'), null)$$, 'active:true');

\echo '===== exemption'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_err('exemption in the past refused', $$select admin_set_exemption(null, (select id from institutes where name='معهد الحرفي'), current_date - 1, 'شريك')$$);
select t_ok('exempt the repeat institute for 60 days', $$select admin_set_exemption(null, (select id from institutes where name='معهد الحرفي'), current_date + 60, 'شريك تجريبي')$$);
select t_is('exempt', $$select state from admin_business_access() where name = 'معهد الحرفي'$$, 'exempt');
select t_ok('revoke the exemption', $$select admin_set_exemption(null, (select id from institutes where name='معهد الحرفي'), null, 'انتهت الشراكة')$$);
select t_is('expired again', $$select state from admin_business_access() where name = 'معهد الحرفي'$$, 'expired');
reset role;

\echo '===== plans'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000a';
select t_err('non-admin cannot change plans', $$select admin_upsert_plan('pro', 'احترافي', 1, 250, true)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_err('bad plan code refused', $$select admin_upsert_plan('Pro Plan', 'احترافي', 1, 250, true)$$);
select t_ok('add a plan', $$select admin_upsert_plan('pro_m1', 'احترافي شهري', 1, 250, true, 9)$$);
select t_ok('change it', $$select admin_upsert_plan('pro_m1', 'احترافي شهري', 1, 230, true, 9)$$);
select t_is('plan price', $$select price::text from plans where code = 'pro_m1'$$, '230');
reset role;

\echo '===== reminders (deduplicated)'
update business_trials set ends_at = now() + interval '2 days 23 hours' where teacher_id = (select id from teachers where name='نفس الهاتف');
select t_is('3-day trial reminder sent', $$select (subscription_reminders() >= 1)::text$$, 'true');
select t_is('reminder text names the trial', $$select count(*)::text from notifications where user_id = '72000000-0000-0000-0000-00000000000e' and kind = 'subscription' and body like '%تجربتك المجانية%'$$, '1');
select subscription_reminders() \g /dev/null
select t_is('not sent twice', $$select count(*)::text from notifications where user_id = '72000000-0000-0000-0000-00000000000e' and kind = 'subscription'$$, '1');
update app_settings set value = 'false' where key = 'subscriptions_required';
select t_is('switch off: no reminders', $$select subscription_reminders()::text$$, '0');
select t_is('switch off: everyone visible again', $$select owner_has_access(null, (select id from institutes where name='معهد الحرفي'))::text$$, 'true');

\echo '===== report and audit'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_is('recorded revenue = the discounted price', $$select (admin_access_report(current_date - 1, current_date)->>'recorded_revenue')$$, '120');
select t_is('discount reported', $$select (admin_access_report(current_date - 1, current_date)->'by_month'->0->>'discounts')$$, '50');
select t_is('report carries the notice', $$select (admin_access_report(current_date - 1, current_date) ? 'notice')::text$$, 'true');
reset role;
select t_is('admin actions audited', $$select (count(*) >= 6)::text from audit_log where action in ('setting_set','trial_extend','exemption_set','exemption_revoke','subscription_discount','plan_upsert')$$, 'true');
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000f';
select t_is('a customer has no business state', $$select count(*)::text from my_access_state()$$, '0');
select t_err('a customer cannot read trials', $$select count(*) from business_trials$$);
reset role;
