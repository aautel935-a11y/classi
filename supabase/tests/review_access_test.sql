-- Who can read unapproved edits and moderation notes (pending_changes, review_note) of teachers, institutes and offers
-- (migration 20261103010000). Only the owner (my_review_state) and admins (admin_review_queue); every other column
-- stays readable as before. Every check prints "PASS: …" or "FAIL: …". Synthetic accounts only (ids 7100…).
\pset pager off
\pset footer off
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
 ('71000000-0000-0000-0000-000000000001','admin@t','{"full_name":"المدير"}'),
 ('71000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر مصاروة"}'),
 ('71000000-0000-0000-0000-000000000003','mom@t','{"full_name":"أم يوسف"}'),
 ('71000000-0000-0000-0000-000000000004','owner@t','{"full_name":"صاحب معهد"}'),
 ('71000000-0000-0000-0000-000000000005','rana@t','{"full_name":"رنا"}');
update profiles set roles = array['admin','guardian']::app_role[] where id = '71000000-0000-0000-0000-000000000001';
update teachers set user_id = '71000000-0000-0000-0000-000000000002' where name = 'سامر مصاروة';
update teachers set user_id = '71000000-0000-0000-0000-000000000005' where name = 'رنا أبو حسين';
update institutes set owner_id = '71000000-0000-0000-0000-000000000004' where name = 'مركز النخبة للتعليم';
create temp table ids as select
  (select id from teachers where name = 'سامر مصاروة') samer,
  (select id from institutes where name = 'مركز النخبة للتعليم') inst,
  (select id from offerings where title = 'رياضيات بجروت 5 وحدات') priv,
  (select id from offerings where title = 'دورة بجروت رياضيات 5 وحدات') crs;
grant select on ids to anon, authenticated;

-- waiting changes and notes, created by the owners themselves (content review moves them into pending_changes)
set role authenticated; set request.jwt.claim.sub = '71000000-0000-0000-0000-000000000002';
update teachers set bio = 'نبذة سرية بانتظار المراجعة' where user_id = auth.uid();
update offerings set title = 'عنوان سري بانتظار المراجعة' where id = (select priv from ids);
reset role;
set role authenticated; set request.jwt.claim.sub = '71000000-0000-0000-0000-000000000004';
update institutes set bio = 'وصف معهد سري' where owner_id = auth.uid();
update offerings set title = 'دورة سرية بانتظار المراجعة' where id = (select crs from ids);
reset role; reset request.jwt.claim.sub;
update teachers set review_note = 'ملاحظة إدارية خاصة' where id = (select samer from ids);

\echo '===== 1. another signed-in user cannot read them'
set role authenticated; set request.jwt.claim.sub = '71000000-0000-0000-0000-000000000003';
select t_err('teachers.pending_changes', $$select pending_changes from teachers limit 1$$);
select t_err('teachers.review_note', $$select review_note from teachers limit 1$$);
select t_err('institutes.pending_changes', $$select pending_changes from institutes limit 1$$);
select t_err('offerings.pending_changes', $$select pending_changes from offerings limit 1$$);
select t_err('offerings.review_note', $$select review_note from offerings limit 1$$);
select t_err('filtering on a hidden column (to guess its content) is refused too', $$select id from teachers where pending_changes::text like '%سرية%'$$);
select t_err('select * includes hidden columns and is refused', $$select * from teachers limit 1$$);
select t_is('my_review_state shows her nothing (she owns nothing)', $$select count(*)::text from my_review_state()$$, '0');
reset role;

\echo '===== 2. everything else stays readable (catalog, profiles, offers)'
set role authenticated; set request.jwt.claim.sub = '71000000-0000-0000-0000-000000000003';
select t_is('teacher public columns', $$select name || ' ' || verify from teachers where id = (select samer from ids)$$, 'سامر مصاروة verified');
select t_is('the live (approved) bio, not the waiting one', $$select (bio not like '%سرية%')::text from teachers where id = (select samer from ids)$$, 'true');
select t_is('offer public columns incl. review_status', $$select title || ' ' || review_status from offerings where id = (select priv from ids)$$, 'رياضيات بجروت 5 وحدات approved');
select t_is('count(*) still works', $$select (count(*) > 0)::text from offerings$$, 'true');
reset role;
set role anon; reset request.jwt.claim.sub;
select t_err('visitors: pending_changes still hidden', $$select pending_changes from teachers limit 1$$);
select t_is('visitors: public columns', $$select name from teachers where id = (select samer from ids)$$, 'سامر مصاروة');
select t_err('visitors cannot call my_review_state', $$select * from my_review_state()$$);
reset role;

\echo '===== 3. the owner reads their own (and only their own)'
set role authenticated; set request.jwt.claim.sub = '71000000-0000-0000-0000-000000000002';
select t_is('Samer: his waiting profile change', $$select pending_changes->>'bio' from my_review_state() where kind = 'teacher'$$, 'نبذة سرية بانتظار المراجعة');
select t_is('Samer: the note about his profile', $$select review_note from my_review_state() where kind = 'teacher'$$, 'ملاحظة إدارية خاصة');
select t_is('Samer: his waiting offer change', $$select pending_changes->>'title' from my_review_state() where kind = 'offering' and id = (select priv from ids)$$, 'عنوان سري بانتظار المراجعة');
select t_is('Samer: nothing of the institute (not his)', $$select count(*)::text from my_review_state() where kind = 'institute' or id = (select crs from ids)$$, '0');
select t_err('Samer still cannot read the columns directly', $$select pending_changes from teachers where user_id = auth.uid()$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '71000000-0000-0000-0000-000000000004';
select t_is('institute owner: the institute''s waiting change', $$select pending_changes->>'bio' from my_review_state() where kind = 'institute'$$, 'وصف معهد سري');
select t_is('institute owner: the course''s waiting change', $$select pending_changes->>'title' from my_review_state() where kind = 'offering' and id = (select crs from ids)$$, 'دورة سرية بانتظار المراجعة');
select t_is('institute owner: nothing of Samer', $$select count(*)::text from my_review_state() where kind = 'teacher' or id = (select priv from ids)$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub = '71000000-0000-0000-0000-000000000005';
select t_is('another teacher (Rana) sees only her own (nothing waiting)', $$select count(*)::text from my_review_state() where pending_changes is not null or review_note is not null$$, '0');
reset role;

\echo '===== 4. the admin keeps full access through the review queue, and decisions work'
set role authenticated; set request.jwt.claim.sub = '71000000-0000-0000-0000-000000000001';
select t_is('queue shows the waiting changes', $$select count(*)::text from admin_review_queue() where changes is not null$$, '4');
select t_is('queue shows the waiting bio', $$select changes->>'bio' from admin_review_queue() where kind = 'teacher'$$, 'نبذة سرية بانتظار المراجعة');
select t_ok('approve Samer''s profile change', $$select admin_review('teacher', (select samer from ids), true)$$);
select t_ok('reject the course change', $$select admin_review('offering', (select crs from ids), false, 'سبب الرفض')$$);
reset role;
select t_is('approved: the new bio is live', $$select bio from teachers where id = (select samer from ids)$$, 'نبذة سرية بانتظار المراجعة');
set role authenticated; set request.jwt.claim.sub = '71000000-0000-0000-0000-000000000004';
select t_is('rejected: the owner reads the reason', $$select review_note from my_review_state() where kind = 'offering' and id = (select crs from ids)$$, 'سبب الرفض');
reset role;

\echo '===== 5. guard for later migrations: every other column is readable by app users and visitors'
select t_is('authenticated: all columns except the two hidden ones',
  $$select coalesce(string_agg(table_name || '.' || column_name, ', '), 'none') from information_schema.columns
     where table_schema = 'public' and table_name in ('teachers', 'institutes', 'offerings')
       and column_name not in ('pending_changes', 'review_note')
       and not has_column_privilege('authenticated', format('public.%I', table_name), column_name, 'SELECT')$$, 'none');
select t_is('authenticated: the two hidden columns are not readable',
  $$select count(*)::text from information_schema.columns where table_schema = 'public' and table_name in ('teachers', 'institutes', 'offerings')
       and column_name in ('pending_changes', 'review_note') and has_column_privilege('authenticated', format('public.%I', table_name), column_name, 'SELECT')$$, '0');
