\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف","phone":"050-123 4567"}'),
 ('40000000-0000-0000-0000-000000000005','dad@t','{"full_name":"أبو آدم","phone":"052 765 4321"}'),
 ('40000000-0000-0000-0000-000000000006','x@t','{"full_name":"بلا رقم"}');
update profiles set sms_ok = false where id = '40000000-0000-0000-0000-000000000005';
select 'phones from signup' t, full_name, phone, sms_ok from profiles order by full_name;
insert into app_secrets values ('dispatch_secret','s') on conflict do nothing;
delete from notifications;
insert into notifications (user_id, kind, body) values
 ('40000000-0000-0000-0000-000000000004','reminder','تذكير: غداً الساعة 17:00'),
 ('40000000-0000-0000-0000-000000000004','booking_answer','تم التأكيد'),
 ('40000000-0000-0000-0000-000000000004','schedule_changed','تغيّر الموعد'),
 ('40000000-0000-0000-0000-000000000005','reminder','تذكير لأبي آدم'),
 ('40000000-0000-0000-0000-000000000006','reminder','تذكير بلا رقم');
set role service_role;
select 'sms targets' t, e->>'kind' kind, e->>'phone' phone from jsonb_array_elements(worker_claim_push(25)) e order by 2, 3;
select 'log' t, worker_log_sms('[{"id":"","phone":"0501234567","ok":true}]');
reset role;
set role anon;
select 'anon writes the SMS log (expect error)' t;
select worker_log_sms('[]');
reset role;
select 'logged' t, count(*) from sms_log;
