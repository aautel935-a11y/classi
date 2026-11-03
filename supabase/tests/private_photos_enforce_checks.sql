-- Private photos, step B (supabase/pending/20261105010000_private_photos_enforce.sql), applied on top of every
-- migration by CI: only the admin adds files to the public bucket; users cannot set public photo links any more, only
-- clear them; the private flow keeps working. PASS:/FAIL: lines. Synthetic accounts only (ids 7400…).
\pset pager off
\pset footer off
set client_min_messages = notice;
insert into auth.users (id, email, raw_user_meta_data) values
 ('74000000-0000-0000-0000-000000000001','admin@t','{"full_name":"المدير"}'),
 ('74000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر مصاروة"}'),
 ('74000000-0000-0000-0000-000000000003','mom@t','{"full_name":"أم يوسف"}');
update profiles set roles = array['admin','guardian']::app_role[] where id = '74000000-0000-0000-0000-000000000001';
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
-- an old public photo set by a server job (before step B): it may be removed, never replaced by the user
update teachers set user_id = '74000000-0000-0000-0000-000000000002', pending_changes = null,
  photo_url = 'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/74000000-0000-0000-0000-000000000002/teacher.jpg' where name = 'سامر مصاروة';
update profiles set avatar_url = 'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/74000000-0000-0000-0000-000000000003/profile-o1-oooooooo.jpg' where id = '74000000-0000-0000-0000-000000000003';
create temp table k as select (select id from teachers where name = 'سامر مصاروة') tid, 'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/'::text base;
grant select on k to anon, authenticated;

\echo '===== 1. nobody but the admin adds files to the public bucket'
set role authenticated; set request.jwt.claim.sub = '74000000-0000-0000-0000-000000000003';
select t_err('a user cannot upload a profile photo to the public bucket', $$insert into storage.objects (bucket_id, name) values ('avatars', '74000000-0000-0000-0000-000000000003/profile-n1-nnnnnnnn.jpg')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '74000000-0000-0000-0000-000000000002';
select t_err('a teacher cannot upload a photo to the public bucket', $$insert into storage.objects (bucket_id, name) values ('avatars', '74000000-0000-0000-0000-000000000002/teacher-n1-nnnnnnnn.jpg')$$);
reset role;
select t_is('no upload/replace policy for users on the public bucket', $$select count(*)::text from pg_policies where tablename = 'objects' and policyname in ('avatars: upload own', 'avatars: replace own')$$, '0');

\echo '===== 2. users cannot set public photo links, only clear them'
set role authenticated; set request.jwt.claim.sub = '74000000-0000-0000-0000-000000000002';
select t_err('a teacher cannot set a public photo link (would wait in pending_changes)', $$update teachers set photo_url = (select base from k) || '74000000-0000-0000-0000-000000000002/teacher-n2-nnnnnnnn.jpg' where user_id = auth.uid()$$);
select t_ok('a teacher can still ask to remove the photo', $$update teachers set photo_url = null where user_id = auth.uid()$$);
select t_ok('other profile edits are unaffected', $$update teachers set bio = 'نبذة' where user_id = auth.uid()$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '74000000-0000-0000-0000-000000000003';
select t_err('a user cannot set a public profile photo', $$update profiles set avatar_url = (select base from k) || '74000000-0000-0000-0000-000000000003/profile-n3-nnnnnnnn.jpg' where id = auth.uid()$$);
select t_ok('a user can clear her old public profile photo', $$update profiles set avatar_url = null where id = auth.uid()$$);
select t_ok('the private flow works: upload', $$insert into storage.objects (bucket_id, name) values ('photos-private', '74000000-0000-0000-0000-000000000003/profile-n4-nnnnnnnn.jpg')$$);
select t_ok('the private flow works: set as profile photo', $$select submit_photo('profile', '74000000-0000-0000-0000-000000000003/profile-n4-nnnnnnnn.jpg')$$);
select t_is('…saved privately', $$select avatar_path || ' ' || coalesce(avatar_url, '-') from profiles where id = auth.uid()$$, '74000000-0000-0000-0000-000000000003/profile-n4-nnnnnnnn.jpg -');
reset role;

\echo '===== 3. the admin publishes; server jobs are unaffected'
set role authenticated; set request.jwt.claim.sub = '74000000-0000-0000-0000-000000000002';
select t_ok('the teacher uploads a waiting photo', $$insert into storage.objects (bucket_id, name) values ('photos-private', '74000000-0000-0000-0000-000000000002/pending/teacher-n5-nnnnnnnn.jpg')$$);
select t_ok('…and puts it up for review', $$select submit_photo('teacher', '74000000-0000-0000-0000-000000000002/pending/teacher-n5-nnnnnnnn.jpg')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '74000000-0000-0000-0000-000000000001';
select t_ok('the admin approves the removal and the bio', $$select admin_review('teacher', (select tid from k), true)$$);
select t_ok('the admin copies the photo to the public bucket', $$insert into storage.objects (bucket_id, name) values ('avatars', '74000000-0000-0000-0000-000000000002/teacher-p5-pppppppp.jpg')$$);
select t_ok('the admin publishes it', $$select admin_publish_photo('teacher', (select tid from k), '74000000-0000-0000-0000-000000000002/pending/teacher-n5-nnnnnnnn.jpg', (select base from k) || '74000000-0000-0000-0000-000000000002/teacher-p5-pppppppp.jpg')$$);
reset role;
select t_is('the published photo is live', $$select photo_url from teachers where id = (select tid from k)$$, 'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/74000000-0000-0000-0000-000000000002/teacher-p5-pppppppp.jpg');
select t_ok('a server job (no signed-in user) still edits freely', $$update teachers set photo_url = null where id = (select tid from k)$$);
select t_is('the guard function is not callable by users', $$select (has_function_privilege('authenticated', 'public.photo_publish_guard()', 'execute') or has_function_privilege('anon', 'public.photo_publish_guard()', 'execute'))::text$$, 'false');
