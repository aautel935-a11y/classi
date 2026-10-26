\pset pager off
\pset footer off
insert into auth.users (id, email, phone, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000002','samer@t', '972521110000', '{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t', '972501234567', '{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000005','dad@t', null, '{"full_name":"أبو سليم"}');
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
insert into children (id, guardian_id, name) values ('70000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000004','يوسف');
create temp table ids as select (select id from offerings where title='رياضيات بجروت 5 وحدات') priv;
-- Mom's son: a lesson in 3 hours (gets the SMS), and one in 1.5 hours for dad (too close: only the 1-hour notice)
insert into bookings (offering_id, booked_by, child_id, starts_at, minutes, status, mode) values
 ((select priv from ids), '40000000-0000-0000-0000-000000000004', '70000000-0000-0000-0000-000000000001', date_trunc('minute', now()) + interval '3 hours', 60, 'confirmed', 'home'),
 ((select priv from ids), '40000000-0000-0000-0000-000000000005', null, date_trunc('minute', now()) + interval '90 minutes', 60, 'confirmed', 'online');
delete from notifications;

\echo '===== 1. Same-day reminders (run twice: no duplicates)'
select 'sent' t, send_today_reminders();
select 'again (expect 0)' t, send_today_reminders();
select 'who got what' t, p.full_name, n.kind, n.body, n.want_push push, n.kind = any(sms_kinds()) sms
  from notifications n join profiles p on p.id = n.user_id order by 2;

\echo '===== 2. Day-before reminder no longer goes by SMS (free channels only); admin notes buzz the phone'
select 'reminder (24h) by sms?' t, 'reminder' = any(sms_kinds());
insert into notifications (user_id, kind, body) values ('40000000-0000-0000-0000-000000000004', 'admin_note', 'من إدارة Classi: تجربة');
select 'admin note push + sms' t, want_push, kind = any(sms_kinds()) from notifications where kind = 'admin_note';
