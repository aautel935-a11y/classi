\pset pager off
\pset footer off
insert into auth.users (id, email, phone, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000001','admin@t', null, '{"full_name":"المدير"}'),
 ('40000000-0000-0000-0000-000000000002','samer@t', null, '{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t', '972501234567', '{"full_name":"أم يوسف"}');
update profiles set roles = array['admin','guardian']::app_role[] where id = '40000000-0000-0000-0000-000000000001';
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
create temp table ids as select (select id from offerings where title='رياضيات بجروت 5 وحدات') priv;
grant select on ids to authenticated;
insert into bookings (id, offering_id, booked_by, starts_at, minutes, status, mode, pay_method, price) values
 ('60000000-0000-0000-0000-000000000001', (select priv from ids), '40000000-0000-0000-0000-000000000004', now() + interval '3 days', 60, 'confirmed', 'home', 'bit', 150),
 ('60000000-0000-0000-0000-000000000002', (select priv from ids), '40000000-0000-0000-0000-000000000004', now() - interval '2 days', 60, 'confirmed', 'home', 'bit', 150);
update bookings set pay_status = 'reported' where id = '60000000-0000-0000-0000-000000000002';
delete from notifications;

\echo '===== 1. Phone complaint: admin finds the family bookings by phone'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000001';
select 'by phone' t, title, owner_name, student, parent_phone, status, pay_status from admin_find_bookings('050-123 4567');
select 'by name' t, count(*) from admin_find_bookings('يوسف');
select 'by teacher' t, count(*) from admin_find_bookings('سامر');
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'parent cannot search (expect error)' t;
select * from admin_find_bookings('050');
reset role;

\echo '===== 2. Dispute: admin settles the payment and cancels the future lesson'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000001';
select 'no reason (expect error)' t;
select admin_set_payment('60000000-0000-0000-0000-000000000002', 'paid', '');
select admin_set_payment('60000000-0000-0000-0000-000000000002', 'paid', 'أرسلت الأم صورة تحويل Bit');
select admin_cancel_booking('60000000-0000-0000-0000-000000000001', 'خلاف على الموعد، باتفاق الطرفين');
select 'cancel twice (expect error)' t;
select admin_cancel_booking('60000000-0000-0000-0000-000000000001', 'x');
reset role;
select 'bookings' t, id, status, pay_status from bookings where id::text like '60000000%' order by id;
select 'told' t, p.full_name, n.kind, left(n.body, 70) from notifications n join profiles p on p.id = n.user_id order by 2, 3;
select 'logged' t, action, target_type, reason from moderation_actions order by created_at;

\echo '===== 3. Direct note, stats, offer title fix'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000001';
select admin_message('40000000-0000-0000-0000-000000000002', 'يرجى تحديث جدولك قبل الغد');
select 'stats' t, admin_stats() - 'top_teachers' stats, admin_stats() -> 'top_teachers' top;
select admin_edit_offer((select priv from ids), 'رياضيات بجروت 5 وحدات، تحضير مكثّف', 'حذفنا رقم الهاتف من العنوان');
reset role;
select 'note goes by sms' t, kind = any(sms_kinds()) from notifications where kind = 'admin_note';
select 'offer' t, title, review_status from offerings where id = (select priv from ids);
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
select 'teacher cannot use admin tools (expect error)' t;
select admin_stats();
reset role;
