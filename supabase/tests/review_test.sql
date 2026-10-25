\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000001','admin@t','{"full_name":"المدير"}'),
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000009','new@t','{"full_name":"معلم جديد"}');
update profiles set roles = array['admin','guardian']::app_role[] where id = '40000000-0000-0000-0000-000000000001';
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
delete from notifications;

\echo '===== 1. Seed offers stay approved; Samer publishes a new offer -> pending, hidden'
select 'seed approved' t, count(*) filter (where review_status = 'approved') ok, count(*) all_ from offerings;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
insert into offerings (type, teacher_id, title, places, price, minutes) values ('private', (select id from teachers where user_id = auth.uid()), 'فيزياء تجريبية للمراجعة', '{home}', 160, 60);
select 'my new offer' t, title, review_status from offerings where title = 'فيزياء تجريبية للمراجعة';
select 'try to self-approve' t;
update offerings set review_status = 'approved' where title = 'فيزياء تجريبية للمراجعة';
select 'still' t, review_status from offerings where title = 'فيزياء تجريبية للمراجعة';
reset role;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'mom sees it? (expect 0)' t, count(*) from offerings where title = 'فيزياء تجريبية للمراجعة';
select 'mom books it (expect error)' t;
select create_booking((select id from offerings where title = 'فيزياء تجريبية للمراجعة' union select id from offerings where false limit 1), null, now() + interval '3 days');
reset role;
select 'admin told' t, body from notifications where user_id = '40000000-0000-0000-0000-000000000001';

\echo '===== 2. Samer edits a published offer: live version unchanged, change waits; price applies now'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
update offerings set title = 'رياضيات بجروت 5 وحدات - مكثف', price = 170 where title = 'رياضيات بجروت 5 وحدات';
select 'live' t, title, price, pending_changes from offerings where teacher_id = (select id from teachers where user_id = auth.uid()) and type = 'private' and review_status = 'approved';
reset role;

\echo '===== 3. Samer changes bio and photo on his verified profile -> held'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000002';
update teachers set bio = 'نبذة جديدة', photo_url = 'https://x/p.jpg' where user_id = auth.uid();
select 'profile live' t, left(bio, 20) bio, photo_url, pending_changes from teachers where user_id = auth.uid();
reset role;

\echo '===== 4. A new unverified teacher edits freely (whole profile reviewed at verification)'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000009';
insert into teachers (user_id, name, town) values (auth.uid(), 'معلم جديد', 'باقة الغربية');
update teachers set bio = 'أنا معلم' where user_id = auth.uid();
select 'new teacher' t, bio, verify, pending_changes from teachers where user_id = auth.uid();
reset role;

\echo '===== 5. Admin queue and decisions'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000001';
select 'queue' t, kind, owner_name, title, what, changes from admin_review_queue();
select admin_review('offering', (select id from offerings where title = 'فيزياء تجريبية للمراجعة'), true);
select admin_review('offering', (select id from offerings where pending_changes is not null), false, 'العنوان مضلل');
select admin_review('teacher', (select id from teachers where user_id = '40000000-0000-0000-0000-000000000002'), true);
select 'queue after' t, count(*) from admin_review_queue();
reset role;
select 'results' t, title, review_status, review_note, pending_changes is null no_pending from offerings where title like 'فيزياء تجريبية%' or title like 'رياضيات بجروت 5%';
select 'profile now' t, bio, photo_url from teachers where user_id = '40000000-0000-0000-0000-000000000002';
select 'samer told' t, body from notifications where user_id = '40000000-0000-0000-0000-000000000002' and kind = 'review_answer' order by created_at;
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select 'mom sees approved' t, count(*) from offerings where title = 'فيزياء تجريبية للمراجعة';
select 'non-admin queue (expect 0)' t, count(*) from admin_review_queue();
select 'non-admin review (expect error)' t;
select admin_review('offering', (select id from offerings limit 1), true);
reset role;
