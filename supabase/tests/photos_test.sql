-- Photos: storage permissions (each user only in their own folder) and the review cycle of a teacher's/institute's
-- photo (the approved photo stays until the admin approves a new one, and stays when a new one is rejected).
-- Every check prints "PASS: …" or "FAIL: …"; run_all.sh fails on any FAIL. Synthetic accounts only (ids 7000…).
\pset pager off
\pset footer off
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
 ('70000000-0000-0000-0000-000000000001','admin@t','{"full_name":"المدير"}'),
 ('70000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر مصاروة"}'),
 ('70000000-0000-0000-0000-000000000003','mom@t','{"full_name":"أم يوسف"}'),
 ('70000000-0000-0000-0000-000000000004','owner@t','{"full_name":"صاحب معهد"}');
update profiles set roles = array['admin','guardian']::app_role[] where id = '70000000-0000-0000-0000-000000000001';
update teachers set user_id = '70000000-0000-0000-0000-000000000002' where name = 'سامر مصاروة';
update institutes set owner_id = '70000000-0000-0000-0000-000000000004' where name = 'مركز النخبة للتعليم';
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
create temp table p as select
  'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/'::text as base,
  '70000000-0000-0000-0000-000000000002'::text as samer,
  '70000000-0000-0000-0000-000000000003'::text as mom,
  (select id from teachers where name = 'سامر مصاروة') as tid,
  (select id from institutes where name = 'مركز النخبة للتعليم') as iid;
grant select on p to anon, authenticated;
-- Samer's approved photo (set by a server job, which edits freely), stored under the old fixed name
update teachers set photo_url = (select base || samer || '/teacher.jpg' from p), pending_changes = null where id = (select tid from p);
insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000002/teacher.jpg'),
                                                     ('avatars', '70000000-0000-0000-0000-000000000003/profile-m1-aaaaaaaa.jpg');
delete from notifications;

\echo '===== 1. storage: each user only in their own folder'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
select t_ok('Samer uploads a new file into his own folder',
  $$insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000002/teacher-s1-bbbbbbbb.jpg')$$);
select t_err('Samer cannot upload into another user''s folder',
  $$insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000003/profile-x1-cccccccc.jpg')$$);
select t_err('Samer cannot upload outside any user folder',
  $$insert into storage.objects (bucket_id, name) values ('avatars', 'teacher-s9-dddddddd.jpg')$$);
reset role;

set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000003';
delete from storage.objects where name = '70000000-0000-0000-0000-000000000002/teacher.jpg';
update storage.objects set name = '70000000-0000-0000-0000-000000000003/stolen.jpg' where name = '70000000-0000-0000-0000-000000000002/teacher.jpg';
select t_err('another user cannot move her own file into Samer''s folder (overwrite attempt)',
  $$update storage.objects set name = '70000000-0000-0000-0000-000000000002/teacher.jpg' where name = '70000000-0000-0000-0000-000000000003/profile-m1-aaaaaaaa.jpg'$$);
reset role;
select t_is('another user''s delete and rename of Samer''s approved file changed nothing',
  $$select count(*)::text from storage.objects where name = '70000000-0000-0000-0000-000000000002/teacher.jpg'$$, '1');
select t_is('her own file is still in her folder',
  $$select count(*)::text from storage.objects where name = '70000000-0000-0000-0000-000000000003/profile-m1-aaaaaaaa.jpg'$$, '1');

set role anon; reset request.jwt.claim.sub;
select t_err('a visitor (not signed in) cannot upload',
  $$insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000002/teacher-a1-eeeeeeee.jpg')$$);
reset role;

set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
delete from storage.objects where name = '70000000-0000-0000-0000-000000000002/teacher-s1-bbbbbbbb.jpg';
reset role;
select t_is('Samer can delete his own file', $$select count(*)::text from storage.objects where name like '%teacher-s1-%'$$, '0');

\echo '===== 2. a new photo waits for review; the approved one keeps showing'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
update teachers set photo_url = (select base || samer || '/teacher-n1-aaaaaaaa.jpg' from p) where user_id = auth.uid();
reset role;
select t_is('the approved photo is still the live one',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher.jpg');
select t_is('the new photo waits in pending_changes',
  $$select replace(pending_changes->>'photo_url', (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher-n1-aaaaaaaa.jpg');
set role anon;
select t_is('visitors see the approved photo',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher.jpg');
select t_err('visitors cannot read the photo waiting for review', $$select pending_changes from teachers limit 1$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
update teachers set pending_changes = null where user_id = auth.uid();
reset role;
select t_is('Samer cannot approve his own photo (pending change kept)',
  $$select (pending_changes ? 'photo_url')::text from teachers where id = (select tid from p)$$, 'true');

\echo '===== 3. the admin rejects it: the old photo stays exactly as it was'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select admin_review('teacher', (select tid from p), false, 'الصورة غير واضحة');
reset role;
select t_is('after rejection the approved photo is unchanged',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher.jpg');
select t_is('after rejection nothing is waiting', $$select coalesce(pending_changes->>'photo_url', 'none') from teachers where id = (select tid from p)$$, 'none');
select t_is('Samer is told', $$select count(*)::text from notifications where user_id = '70000000-0000-0000-0000-000000000002' and body like 'لم تتم الموافقة%'$$, '1');

\echo '===== 4. another new photo, approved: it becomes the live photo'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
update teachers set photo_url = (select base || samer || '/teacher-n2-bbbbbbbb.jpg' from p) where user_id = auth.uid();
reset role;
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select admin_review('teacher', (select tid from p), true);
reset role;
select t_is('after approval the new photo is live',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher-n2-bbbbbbbb.jpg');

\echo '===== 5. removing the photo also waits for review'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
update teachers set photo_url = null where user_id = auth.uid();
reset role;
select t_is('while the removal waits, the approved photo still shows',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher-n2-bbbbbbbb.jpg');
select t_is('the removal is waiting', $$select (pending_changes ? 'photo_url' and pending_changes->'photo_url' = 'null'::jsonb)::text from teachers where id = (select tid from p)$$, 'true');
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select admin_review('teacher', (select tid from p), true);
reset role;
select t_is('after approval the photo is gone', $$select coalesce(photo_url, 'none') from teachers where id = (select tid from p)$$, 'none');

\echo '===== 6. institute logo: same cycle'
update institutes set logo_url = (select base || '70000000-0000-0000-0000-000000000004/institute.jpg' from p), pending_changes = null where id = (select iid from p);
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000004';
update institutes set logo_url = (select base || '70000000-0000-0000-0000-000000000004/institute-l1-aaaaaaaa.jpg' from p) where owner_id = auth.uid();
reset role;
select t_is('the approved logo stays while the new one waits',
  $$select replace(logo_url, (select base from p), '') from institutes where id = (select iid from p)$$, '70000000-0000-0000-0000-000000000004/institute.jpg');
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select admin_review('institute', (select iid from p), false);
reset role;
select t_is('rejected: the approved logo is unchanged',
  $$select replace(logo_url, (select base from p), '') from institutes where id = (select iid from p)$$, '70000000-0000-0000-0000-000000000004/institute.jpg');

\echo '===== 7. links outside Classi storage are refused by the database'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000003';
select t_err('a profile photo on another site is refused',
  $$update profiles set avatar_url = 'https://evil.example/x.jpg' where id = auth.uid()$$);
select t_ok('a profile photo in Classi storage is saved directly (no review for profile photos)',
  $$update profiles set avatar_url = (select base || mom || '/profile-m1-aaaaaaaa.jpg' from p) where id = auth.uid()$$);
reset role;
