-- Private photos, step A (migration 20261105000000_private_photos): bucket "photos-private" permissions, submit_photo,
-- admin_publish_photo, admin_review keeping a waiting photo, profiles.avatar_path. PASS:/FAIL: lines.
-- Synthetic accounts only (ids 7300…).
\pset pager off
\pset footer off
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
 ('73000000-0000-0000-0000-000000000001','admin@t','{"full_name":"المدير"}'),
 ('73000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر مصاروة"}'),
 ('73000000-0000-0000-0000-000000000003','mom@t','{"full_name":"أم يوسف"}'),
 ('73000000-0000-0000-0000-000000000004','owner@t','{"full_name":"صاحب معهد"}');
update profiles set roles = array['admin','guardian']::app_role[] where id = '73000000-0000-0000-0000-000000000001';
update teachers set user_id = '73000000-0000-0000-0000-000000000002', photo_url = null, pending_changes = null where name = 'سامر مصاروة';
update institutes set owner_id = '73000000-0000-0000-0000-000000000004', pending_changes = null where name = 'مركز النخبة للتعليم';
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
create temp table k as select
  'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/'::text base,
  (select id from teachers where name = 'سامر مصاروة') tid, (select verify::text from teachers where name = 'سامر مصاروة') tverify,
  (select id from institutes where name = 'مركز النخبة للتعليم') iid;
grant select on k to anon, authenticated;
delete from notifications;

\echo '===== 1. the bucket'
select t_is('photos-private exists and is not public', $$select public::text from storage.buckets where id = 'photos-private'$$, 'false');
select t_is('size and type limits', $$select file_size_limit || ' ' || array_to_string(allowed_mime_types, ',') from storage.buckets where id = 'photos-private'$$, '2097152 image/jpeg,image/png,image/webp');

\echo '===== 2. owners upload into their own folder, with exact names only'
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000002';
select t_ok('Samer uploads a waiting teacher photo', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000002/pending/teacher-m1-aaaaaaaa.jpg')$$);
select t_ok('Samer uploads a profile photo', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000002/profile-m1-bbbbbbbb.jpg')$$);
select t_err('not into another user''s folder', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000003/profile-m1-cccccccc.jpg')$$);
select t_err('not a profile photo under pending/', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000002/pending/profile-m1-dddddddd.jpg')$$);
select t_err('not a waiting photo outside pending/', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000002/teacher-m1-eeeeeeee.jpg')$$);
select t_err('not a free-form name', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000002/pending/anything.png')$$);
select t_err('not a deeper path', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000002/pending/x/teacher-m1-ffffffff.jpg')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000003';
select t_ok('the mother uploads her profile photo', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000003/profile-m1-gggggggg.jpg')$$);
reset role;
set role anon; reset request.jwt.claim.sub;
select t_err('a visitor cannot upload', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000002/profile-m2-hhhhhhhh.jpg')$$);
reset role;

\echo '===== 3. who can read (list) private files'
set role anon; reset request.jwt.claim.sub;
select t_is('visitor: nothing', $$select count(*)::text from storage.objects where bucket_id = 'photos-private'$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000003';
select t_is('the mother: only her own profile photo', $$select string_agg(name, ',') from storage.objects where bucket_id = 'photos-private'$$, '73000000-0000-0000-0000-000000000003/profile-m1-gggggggg.jpg');
reset role;
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000002';
select t_is('Samer: his two files', $$select count(*)::text from storage.objects where bucket_id = 'photos-private'$$, '2');
reset role;
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000001';
select t_is('admin: the waiting photo only, never profile photos', $$select string_agg(name, ',') from storage.objects where bucket_id = 'photos-private'$$, '73000000-0000-0000-0000-000000000002/pending/teacher-m1-aaaaaaaa.jpg');
reset role;

\echo '===== 4. who can delete private files'
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000003';
delete from storage.objects where bucket_id = 'photos-private' and name like '73000000-0000-0000-0000-000000000002/%';
reset role;
select t_is('another user deletes nothing of Samer''s', $$select count(*)::text from storage.objects where bucket_id = 'photos-private' and name like '73000000-0000-0000-0000-000000000002/%'$$, '2');
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000001';
delete from storage.objects where bucket_id = 'photos-private' and name like '%/profile-%';
reset role;
select t_is('the admin cannot delete profile photos', $$select count(*)::text from storage.objects where bucket_id = 'photos-private' and name like '%/profile-%'$$, '2');
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000002';
select t_ok('Samer uploads and deletes a file of his own', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000002/pending/teacher-m9-zzzzzzzz.jpg')$$);
delete from storage.objects where name = '73000000-0000-0000-0000-000000000002/pending/teacher-m9-zzzzzzzz.jpg';
reset role;
select t_is('…and it is gone', $$select count(*)::text from storage.objects where name like '%teacher-m9-%'$$, '0');
select t_is('no update policy on private files (never overwritten)', $$select count(*)::text from pg_policies where tablename = 'objects' and cmd in ('UPDATE', 'ALL') and qual like '%photos-private%'$$, '0');
select t_is('no private-photo policy for visitors or for everyone', $$select count(*)::text from pg_policies where tablename = 'objects' and (coalesce(qual, '') || coalesce(with_check, '')) like '%photos-private%' and (roles && array['public', 'anon']::name[])$$, '0');

\echo '===== 5. submit_photo'
set role anon; reset request.jwt.claim.sub;
select t_err('visitors cannot call it', $$select submit_photo('profile', '73000000-0000-0000-0000-000000000002/profile-m1-bbbbbbbb.jpg')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000003';
select t_err('another user''s file is refused', $$select submit_photo('profile', '73000000-0000-0000-0000-000000000002/profile-m1-bbbbbbbb.jpg')$$);
select t_err('a file that was never uploaded is refused', $$select submit_photo('profile', '73000000-0000-0000-0000-000000000003/profile-m7-nnnnnnnn.jpg')$$);
select t_err('a profile photo cannot be put up as a teacher photo', $$select submit_photo('teacher', '73000000-0000-0000-0000-000000000003/profile-m1-gggggggg.jpg')$$);
select t_ok('the mother sets her private profile photo', $$select submit_photo('profile', '73000000-0000-0000-0000-000000000003/profile-m1-gggggggg.jpg')$$);
select t_is('…saved as a path, no public link', $$select avatar_path || ' ' || coalesce(avatar_url, '-') from profiles where id = auth.uid()$$, '73000000-0000-0000-0000-000000000003/profile-m1-gggggggg.jpg -');
select t_err('the mother has no teacher profile to put a photo up for', $$select submit_photo('teacher', '73000000-0000-0000-0000-000000000003/pending/teacher-m1-aaaaaaaa.jpg')$$);
select t_err('avatar_path cannot point at someone else''s file (constraint)', $$update profiles set avatar_path = '73000000-0000-0000-0000-000000000002/profile-m1-bbbbbbbb.jpg' where id = auth.uid()$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000002';
select t_is('Samer puts his photo up for review (nothing waited before)', $$select coalesce(submit_photo('teacher', '73000000-0000-0000-0000-000000000002/pending/teacher-m1-aaaaaaaa.jpg'), 'none')$$, 'none');
reset role;
select t_is('it waits as a private path; the live photo is unchanged (none)', $$select (pending_changes ->> 'photo_path') || ' | ' || coalesce(photo_url, '-') from teachers where id = (select tid from k)$$,
  '73000000-0000-0000-0000-000000000002/pending/teacher-m1-aaaaaaaa.jpg | -');
select t_is('the admins are told', $$select count(*)::text from notifications where kind = 'review_needed' and body like 'صورة معلم جديدة%'$$, '1');
select t_is('the review bypass is not left switched on', $$select coalesce(current_setting('classi.bypass_review', true), '')$$, '');
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000002';
select t_ok('Samer uploads a second photo', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000002/pending/teacher-m2-aaaaaaa2.jpg')$$);
select t_is('a newer photo replaces the waiting one; the previous path is returned (the app deletes that file)', $$select submit_photo('teacher', '73000000-0000-0000-0000-000000000002/pending/teacher-m2-aaaaaaa2.jpg')$$,
  '73000000-0000-0000-0000-000000000002/pending/teacher-m1-aaaaaaaa.jpg');
select t_ok('a bio edit while the photo waits', $$update teachers set bio = 'نبذة جديدة أثناء انتظار الصورة' where user_id = auth.uid()$$);
reset role;
select t_is('the photo is still waiting next to the other change', $$select (pending_changes ? 'photo_path')::text from teachers where id = (select tid from k)$$, 'true');

\echo '===== 6. admin_review keeps a waiting photo waiting; admin_publish_photo publishes it'
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000001';
select t_ok('the admin approves the profile edits', $$select admin_review('teacher', (select tid from k), true)$$);
reset role;
select t_is('other fields applied, the photo still waits, still no live photo', $$select (pending_changes ->> 'photo_path') || ' | ' || coalesce(photo_url, '-') from teachers where id = (select tid from k)$$,
  '73000000-0000-0000-0000-000000000002/pending/teacher-m2-aaaaaaa2.jpg | -');
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000002';
select t_err('the owner cannot publish', $$select admin_publish_photo('teacher', (select tid from k), '73000000-0000-0000-0000-000000000002/pending/teacher-m2-aaaaaaa2.jpg', (select base from k) || '73000000-0000-0000-0000-000000000002/teacher-p1-pppppppp.jpg')$$);
select t_err('the owner cannot add files to the public bucket as the admin does', $$insert into storage.objects (bucket_id, name) values ('avatars', '73000000-0000-0000-0000-000000000004/teacher-p1-pppppppp.jpg')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000001';
select t_err('publishing before the file was copied to the public bucket is refused', $$select admin_publish_photo('teacher', (select tid from k), '73000000-0000-0000-0000-000000000002/pending/teacher-m2-aaaaaaa2.jpg', (select base from k) || '73000000-0000-0000-0000-000000000002/teacher-p1-pppppppp.jpg')$$);
select t_ok('the admin copies the approved photo into the owner''s public folder', $$insert into storage.objects (bucket_id, name) values ('avatars', '73000000-0000-0000-0000-000000000002/teacher-p1-pppppppp.jpg')$$);
select t_err('the admin cannot put a profile photo in the public bucket', $$insert into storage.objects (bucket_id, name) values ('avatars', '73000000-0000-0000-0000-000000000003/profile-p1-pppppppp.jpg')$$);
select t_err('publishing a path that is not the waiting one is refused', $$select admin_publish_photo('teacher', (select tid from k), '73000000-0000-0000-0000-000000000002/pending/teacher-m1-aaaaaaaa.jpg', (select base from k) || '73000000-0000-0000-0000-000000000002/teacher-p1-pppppppp.jpg')$$);
select t_err('publishing a link in another folder is refused', $$select admin_publish_photo('teacher', (select tid from k), '73000000-0000-0000-0000-000000000002/pending/teacher-m2-aaaaaaa2.jpg', (select base from k) || '73000000-0000-0000-0000-000000000003/teacher-p1-pppppppp.jpg')$$);
select t_is('publishing the waiting photo; it returns the previous live photo (none)', $$select coalesce(admin_publish_photo('teacher', (select tid from k), '73000000-0000-0000-0000-000000000002/pending/teacher-m2-aaaaaaa2.jpg', (select base from k) || '73000000-0000-0000-0000-000000000002/teacher-p1-pppppppp.jpg'), 'none')$$, 'none');
select t_is('the admin reads the owner''s public teacher photo (to replace it later)', $$select count(*)::text from storage.objects where bucket_id = 'avatars' and name like '73000000-0000-0000-0000-000000000002/teacher-%'$$, '1');
select t_ok('the admin deletes the published private original', $$delete from storage.objects where bucket_id = 'photos-private' and name = '73000000-0000-0000-0000-000000000002/pending/teacher-m2-aaaaaaa2.jpg'$$);
reset role;
select t_is('live photo set, nothing waits any more', $$select photo_url || ' | ' || coalesce(pending_changes::text, '-') from teachers where id = (select tid from k)$$,
  'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/73000000-0000-0000-0000-000000000002/teacher-p1-pppppppp.jpg | -');
select t_is('the private original is gone', $$select count(*)::text from storage.objects where name = '73000000-0000-0000-0000-000000000002/pending/teacher-m2-aaaaaaa2.jpg'$$, '0');
select t_is('the owner is told', $$select count(*)::text from notifications where user_id = '73000000-0000-0000-0000-000000000002' and body like 'تمت الموافقة على صورتك%'$$, '1');
select t_is('the action is logged', $$select count(*)::text from moderation_actions where action = 'photo_publish' and target_id = (select tid from k)$$, '1');

\echo '===== 7. rejection drops the waiting photo; institutes work the same way'
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000004';
select t_ok('the institute owner uploads a waiting logo', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73000000-0000-0000-0000-000000000004/pending/institute-m1-iiiiiiii.jpg')$$);
select t_ok('…and puts it up for review', $$select submit_photo('institute', '73000000-0000-0000-0000-000000000004/pending/institute-m1-iiiiiiii.jpg')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000001';
select t_is('the admin sees it in the review queue as a private path', $$select changes ->> 'photo_path' from admin_review_queue() where kind = 'institute'$$, '73000000-0000-0000-0000-000000000004/pending/institute-m1-iiiiiiii.jpg');
select t_ok('the admin rejects', $$select admin_review('institute', (select iid from k), false, 'شعار غير مناسب')$$);
select t_ok('…and deletes the waiting file', $$delete from storage.objects where bucket_id = 'photos-private' and name = '73000000-0000-0000-0000-000000000004/pending/institute-m1-iiiiiiii.jpg'$$);
reset role;
select t_is('nothing waits, the logo is unchanged, the file is gone', $$select coalesce(pending_changes::text, '-') || ' | ' || coalesce(logo_url, '-') || ' | ' || (select count(*) from storage.objects where name like '%institute-m1-%') from institutes where id = (select iid from k)$$, '- | - | 0');
set role authenticated; set request.jwt.claim.sub = '73000000-0000-0000-0000-000000000004';
select t_is('the owner reads the reason through my_review_state', $$select review_note from my_review_state() where kind = 'institute'$$, 'شعار غير مناسب');
reset role;

