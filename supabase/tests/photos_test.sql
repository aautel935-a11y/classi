-- Photos: storage permissions and the review cycle of a teacher's/institute's photo, with private photos
-- (20261105000000 + 20261105010000): users upload only to the private bucket; a new teacher/institute photo waits there
-- and becomes public only when the admin publishes it; the approved photo stays until then, and stays when a new one
-- is rejected. Users can no longer write to the public bucket or set public photo links (only clear them).
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

\echo '===== 1. public bucket: nobody but the admin adds files; each user only in their own folder'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
select t_err('Samer cannot upload into his own public folder any more (private bucket only)',
  $$insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000002/teacher-s1-bbbbbbbb.jpg')$$);
select t_err('Samer cannot upload into another user''s folder',
  $$insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000003/profile-x1-cccccccc.jpg')$$);
select t_err('Samer cannot upload outside any user folder',
  $$insert into storage.objects (bucket_id, name) values ('avatars', 'teacher-s9-dddddddd.jpg')$$);
reset role;

set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000003';
delete from storage.objects where name = '70000000-0000-0000-0000-000000000002/teacher.jpg';
update storage.objects set name = '70000000-0000-0000-0000-000000000003/stolen.jpg' where name = '70000000-0000-0000-0000-000000000002/teacher.jpg';
update storage.objects set name = '70000000-0000-0000-0000-000000000002/teacher.jpg' where name = '70000000-0000-0000-0000-000000000003/profile-m1-aaaaaaaa.jpg';
reset role;
select t_is('another user''s delete and rename of Samer''s approved file changed nothing',
  $$select count(*)::text from storage.objects where name = '70000000-0000-0000-0000-000000000002/teacher.jpg'$$, '1');
select t_is('her own file was not moved into Samer''s folder (no file is ever renamed)',
  $$select count(*)::text from storage.objects where name = '70000000-0000-0000-0000-000000000003/profile-m1-aaaaaaaa.jpg'$$, '1');

set role anon; reset request.jwt.claim.sub;
select t_err('a visitor (not signed in) cannot upload',
  $$insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000002/teacher-a1-eeeeeeee.jpg')$$);
reset role;

-- an old file in Samer's public folder (put there before private photos): he can still delete his own files
insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000002/teacher-s1-bbbbbbbb.jpg');
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
delete from storage.objects where name = '70000000-0000-0000-0000-000000000002/teacher-s1-bbbbbbbb.jpg';
reset role;
select t_is('Samer can delete his own old public file', $$select count(*)::text from storage.objects where name like '%teacher-s1-%'$$, '0');

\echo '===== 2. a new photo waits privately for review; the approved one keeps showing'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
select t_err('Samer cannot set a public photo link himself',
  $$update teachers set photo_url = (select base || samer || '/teacher-n1-aaaaaaaa.jpg' from p) where user_id = auth.uid()$$);
select t_ok('Samer uploads his new photo to the private bucket',
  $$insert into storage.objects (bucket_id, name) values ('photos-private', '70000000-0000-0000-0000-000000000002/pending/teacher-n1-aaaaaaaa.jpg')$$);
select t_ok('…and puts it up for review', $$select submit_photo('teacher', '70000000-0000-0000-0000-000000000002/pending/teacher-n1-aaaaaaaa.jpg')$$);
reset role;
select t_is('the approved photo is still the live one',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher.jpg');
select t_is('the new photo waits as a private path',
  $$select pending_changes->>'photo_path' from teachers where id = (select tid from p)$$, '70000000-0000-0000-0000-000000000002/pending/teacher-n1-aaaaaaaa.jpg');
select t_is('nothing new in the public bucket before approval',
  $$select count(*)::text from storage.objects where bucket_id = 'avatars' and name like '70000000-0000-0000-0000-000000000002/%'$$, '1');
set role anon;
select t_is('visitors see the approved photo',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher.jpg');
select t_err('visitors cannot read the photo waiting for review', $$select pending_changes from teachers limit 1$$);
select t_is('visitors cannot list the waiting file', $$select count(*)::text from storage.objects where bucket_id = 'photos-private'$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
update teachers set pending_changes = null where user_id = auth.uid();
reset role;
select t_is('Samer cannot clear or approve his own waiting photo (pending change kept)',
  $$select (pending_changes ? 'photo_path')::text from teachers where id = (select tid from p)$$, 'true');

\echo '===== 3. the admin rejects it: the old photo stays exactly as it was'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select admin_review('teacher', (select tid from p), false, 'الصورة غير واضحة');
delete from storage.objects where bucket_id = 'photos-private' and name = '70000000-0000-0000-0000-000000000002/pending/teacher-n1-aaaaaaaa.jpg';
reset role;
select t_is('after rejection the approved photo is unchanged',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher.jpg');
select t_is('after rejection nothing is waiting', $$select coalesce(pending_changes->>'photo_path', 'none') from teachers where id = (select tid from p)$$, 'none');
select t_is('the rejected file is deleted at once (by the admin)', $$select count(*)::text from storage.objects where name like '%teacher-n1-%'$$, '0');
select t_is('Samer is told', $$select count(*)::text from notifications where user_id = '70000000-0000-0000-0000-000000000002' and body like 'لم تتم الموافقة%'$$, '1');

\echo '===== 4. another new photo, approved: the admin publishes it and it becomes the live photo'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
insert into storage.objects (bucket_id, name) values ('photos-private', '70000000-0000-0000-0000-000000000002/pending/teacher-n2-bbbbbbbb.jpg');
select submit_photo('teacher', '70000000-0000-0000-0000-000000000002/pending/teacher-n2-bbbbbbbb.jpg');
reset role;
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select admin_review('teacher', (select tid from p), true);
insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000002/teacher-p2-bbbbbbbb.jpg');
select t_is('publishing returns the previous live photo (to delete)', $$select replace(admin_publish_photo('teacher', (select tid from p), '70000000-0000-0000-0000-000000000002/pending/teacher-n2-bbbbbbbb.jpg', (select base || samer || '/teacher-p2-bbbbbbbb.jpg' from p)), (select base || samer || '/' from p), '')$$, 'teacher.jpg');
select t_ok('the admin deletes the previous public photo', $$delete from storage.objects where bucket_id = 'avatars' and name = '70000000-0000-0000-0000-000000000002/teacher.jpg'$$);
reset role;
select t_is('after approval the new photo is live',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher-p2-bbbbbbbb.jpg');
select t_is('the previous public file is gone', $$select count(*)::text from storage.objects where name = '70000000-0000-0000-0000-000000000002/teacher.jpg'$$, '0');

\echo '===== 5. removing the photo also waits for review'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
select t_ok('Samer asks to remove his photo', $$update teachers set photo_url = null where user_id = auth.uid()$$);
reset role;
select t_is('while the removal waits, the approved photo still shows',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher-p2-bbbbbbbb.jpg');
select t_is('the removal is waiting', $$select (pending_changes ? 'photo_url' and pending_changes->'photo_url' = 'null'::jsonb)::text from teachers where id = (select tid from p)$$, 'true');
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select admin_review('teacher', (select tid from p), true);
reset role;
select t_is('after approval the photo is gone', $$select coalesce(photo_url, 'none') from teachers where id = (select tid from p)$$, 'none');

\echo '===== 6. institute logo: same cycle'
update institutes set logo_url = (select base || '70000000-0000-0000-0000-000000000004/institute.jpg' from p), pending_changes = null where id = (select iid from p);
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000004';
select t_err('the owner cannot set a public logo link himself',
  $$update institutes set logo_url = (select base || '70000000-0000-0000-0000-000000000004/institute-l1-aaaaaaaa.jpg' from p) where owner_id = auth.uid()$$);
insert into storage.objects (bucket_id, name) values ('photos-private', '70000000-0000-0000-0000-000000000004/pending/institute-l1-aaaaaaaa.jpg');
select t_ok('the owner puts a new logo up for review', $$select submit_photo('institute', '70000000-0000-0000-0000-000000000004/pending/institute-l1-aaaaaaaa.jpg')$$);
reset role;
select t_is('the approved logo stays while the new one waits',
  $$select replace(logo_url, (select base from p), '') from institutes where id = (select iid from p)$$, '70000000-0000-0000-0000-000000000004/institute.jpg');
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select admin_review('institute', (select iid from p), false);
reset role;
select t_is('rejected: the approved logo is unchanged',
  $$select replace(logo_url, (select base from p), '') from institutes where id = (select iid from p)$$, '70000000-0000-0000-0000-000000000004/institute.jpg');

\echo '===== 7. profile photos are private; links outside Classi storage are refused'
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000003';
select t_err('a profile photo on another site is refused',
  $$update profiles set avatar_url = 'https://evil.example/x.jpg' where id = auth.uid()$$);
select t_err('a public profile photo link is refused (profile photos are private now)',
  $$update profiles set avatar_url = (select base || mom || '/profile-m1-aaaaaaaa.jpg' from p) where id = auth.uid()$$);
insert into storage.objects (bucket_id, name) values ('photos-private', '70000000-0000-0000-0000-000000000003/profile-m2-aaaaaaaa.jpg');
select t_ok('a private profile photo is saved directly (no review for profile photos)',
  $$select submit_photo('profile', '70000000-0000-0000-0000-000000000003/profile-m2-aaaaaaaa.jpg')$$);
reset role;

\echo '===== 8. a photo link must be in its owner''s own folder (migration 20261103000000), also when the admin publishes'
-- the admin has no direct write on teachers/institutes (row security): photos are set only by admin_publish_photo
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
insert into storage.objects (bucket_id, name) values ('photos-private', '70000000-0000-0000-0000-000000000002/pending/teacher-n3-cccccccc.jpg');
select submit_photo('teacher', '70000000-0000-0000-0000-000000000002/pending/teacher-n3-cccccccc.jpg');
reset role;
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
update teachers set photo_url = (select base || mom || '/profile-m1-aaaaaaaa.jpg' from p) where id = (select tid from p);
reset role;
select t_is('a direct write by the admin changes nothing (no write right on teachers)', $$select coalesce(photo_url, 'none') from teachers where id = (select tid from p)$$, 'none');
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000001';
select t_err('publishing a link to another user''s file is refused',
  $$select admin_publish_photo('teacher', (select tid from p), '70000000-0000-0000-0000-000000000002/pending/teacher-n3-cccccccc.jpg', (select base || mom || '/profile-m1-aaaaaaaa.jpg' from p))$$);
select t_err('the trick of a deeper path is refused',
  $$select admin_publish_photo('teacher', (select tid from p), '70000000-0000-0000-0000-000000000002/pending/teacher-n3-cccccccc.jpg', (select base || samer || '/../' || mom || '/teacher-n3-cccccccc.jpg' from p))$$);
select t_err('publishing a logo link to another user''s file is refused',
  $$select admin_publish_photo('institute', (select iid from p), '70000000-0000-0000-0000-000000000004/pending/institute-l1-aaaaaaaa.jpg', (select base || samer || '/institute-l9-aaaaaaaa.jpg' from p))$$);
insert into storage.objects (bucket_id, name) values ('avatars', '70000000-0000-0000-0000-000000000002/teacher-p3-cccccccc.jpg');
select t_ok('publishing the waiting photo into the owner''s folder passes the check',
  $$select admin_publish_photo('teacher', (select tid from p), '70000000-0000-0000-0000-000000000002/pending/teacher-n3-cccccccc.jpg', (select base || samer || '/teacher-p3-cccccccc.jpg' from p))$$);
reset role;
select t_is('approved photo is the one from his folder',
  $$select replace(photo_url, (select base || samer || '/' from p), '') from teachers where id = (select tid from p)$$, 'teacher-p3-cccccccc.jpg');
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000002';
select t_ok('an unrelated edit (bio) still works', $$update teachers set bio = 'نبذة للاختبار' where user_id = auth.uid()$$);
reset role;
-- existing rows are never blocked: a legacy value (set by a server job) does not stop unrelated updates by the owner
reset request.jwt.claim.sub;
update profiles set avatar_url = (select base || samer || '/legacy.jpg' from p) where id = '70000000-0000-0000-0000-000000000003';
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000003';
select t_ok('an owner with an old value elsewhere can still update other fields', $$update profiles set town = 'باقة الغربية' where id = auth.uid()$$);
select t_ok('and can remove the old public photo', $$update profiles set avatar_url = null where id = auth.uid()$$);
reset role; reset request.jwt.claim.sub;
select t_ok('server jobs (no signed-in user) are not affected',
  $$update profiles set avatar_url = (select base || samer || '/x.jpg' from p) where id = '70000000-0000-0000-0000-000000000003'$$);
set role authenticated; set request.jwt.claim.sub = '70000000-0000-0000-0000-000000000003';
select t_err('app users cannot call the internal check functions', $$select photo_in_folder('x', auth.uid())$$);
reset role;
