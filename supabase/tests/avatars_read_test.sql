-- Photos bucket: who can list (read the rows of) storage.objects (migration 20261104000000_avatars_read_own).
-- Only the signed-in owner, and only their own folder. Upload, delete and the app's cleanup keep working; the bucket
-- stays public (public links do not use these policies). Every check prints "PASS: …" or "FAIL: …".
-- Synthetic accounts only (ids 7200…).
\pset pager off
\pset footer off
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
 ('72000000-0000-0000-0000-000000000001','admin@t','{"full_name":"المدير"}'),
 ('72000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر مصاروة"}'),
 ('72000000-0000-0000-0000-000000000003','mom@t','{"full_name":"أم يوسف"}');
update profiles set roles = array['admin','guardian']::app_role[] where id = '72000000-0000-0000-0000-000000000001';
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
-- files as a server job puts them (no signed-in user): Samer has an approved photo, one waiting for review and one
-- rejected; the mother has a profile photo
insert into storage.objects (bucket_id, name) values
 ('avatars', '72000000-0000-0000-0000-000000000002/teacher-a1-aaaaaaaa.jpg'),
 ('avatars', '72000000-0000-0000-0000-000000000002/teacher-p1-pppppppp.jpg'),
 ('avatars', '72000000-0000-0000-0000-000000000002/teacher-r1-rrrrrrrr.jpg'),
 ('avatars', '72000000-0000-0000-0000-000000000003/profile-m1-mmmmmmmm.jpg');

\echo '===== 1. a visitor (public app key, not signed in) lists nothing'
set role anon; reset request.jwt.claim.sub;
select t_is('visitor: no row of the photos bucket', $$select count(*)::text from storage.objects where bucket_id = 'avatars'$$, '0');
select t_is('visitor: no folder name (user id) at the root', $$select count(distinct (storage.foldername(name))[1])::text from storage.objects where bucket_id = 'avatars'$$, '0');
select t_is('visitor: not Samer''s waiting or rejected photo by name', $$select count(*)::text from storage.objects where name like '72000000-0000-0000-0000-000000000002/%'$$, '0');
select t_err('visitor: still cannot upload', $$insert into storage.objects (bucket_id, name) values ('avatars', '72000000-0000-0000-0000-000000000002/teacher-x1-xxxxxxxx.jpg')$$);
reset role;

\echo '===== 2. another signed-in user lists only her own folder'
set role authenticated; set request.jwt.claim.sub = '72000000-0000-0000-0000-000000000003';
select t_is('the mother: only her own file', $$select string_agg(name, ',') from storage.objects where bucket_id = 'avatars'$$, '72000000-0000-0000-0000-000000000003/profile-m1-mmmmmmmm.jpg');
select t_is('the mother: nothing in Samer''s folder (the list API asks for a folder by prefix)', $$select count(*)::text from storage.objects where bucket_id = 'avatars' and name like '72000000-0000-0000-0000-000000000002/%'$$, '0');
select t_is('the mother: no other user id at the root', $$select string_agg(distinct (storage.foldername(name))[1], ',') from storage.objects where bucket_id = 'avatars'$$, '72000000-0000-0000-0000-000000000003');
-- delete and rename of someone else's file change nothing (as before)
delete from storage.objects where name like '72000000-0000-0000-0000-000000000002/%';
update storage.objects set name = '72000000-0000-0000-0000-000000000003/stolen.jpg' where name = '72000000-0000-0000-0000-000000000002/teacher-a1-aaaaaaaa.jpg';
reset role;
select t_is('Samer''s three files are untouched', $$select count(*)::text from storage.objects where name like '72000000-0000-0000-0000-000000000002/%'$$, '3');

\echo '===== 3. the admin is a signed-in user like any other here (review works through public links)'
set role authenticated; set request.jwt.claim.sub = '72000000-0000-0000-0000-000000000001';
select t_is('admin: nothing listed (no photo of her own)', $$select count(*)::text from storage.objects where bucket_id = 'avatars'$$, '0');
-- the health check lists the root of the bucket: an empty list, not an error
select t_ok('health check (list the root) runs without an error', $$select count(*) from storage.objects where bucket_id = 'avatars' and name not like '%/%/%'$$);
reset role;

\echo '===== 4. the owner: lists, uploads, deletes and cleans up his own folder'
set role authenticated; set request.jwt.claim.sub = '72000000-0000-0000-0000-000000000002';
select t_is('Samer lists his own three files', $$select count(*)::text from storage.objects where bucket_id = 'avatars' and name like '72000000-0000-0000-0000-000000000002/%'$$, '3');
select t_is('Samer sees nobody else''s file', $$select count(*)::text from storage.objects where bucket_id = 'avatars' and name not like '72000000-0000-0000-0000-000000000002/%'$$, '0');
select t_ok('Samer uploads a new file into his own folder (returning the row, as the storage API does)',
  $$insert into storage.objects (bucket_id, name) values ('avatars', '72000000-0000-0000-0000-000000000002/teacher-n1-nnnnnnnn.jpg') returning id$$);
select t_is('the new file is listed', $$select count(*)::text from storage.objects where name = '72000000-0000-0000-0000-000000000002/teacher-n1-nnnnnnnn.jpg'$$, '1');
select t_err('Samer still cannot upload into the mother''s folder', $$insert into storage.objects (bucket_id, name) values ('avatars', '72000000-0000-0000-0000-000000000003/profile-s1-ssssssss.jpg')$$);
-- the cleanup (tidyPhotos): list the own folder, keep the photos in use (approved + waiting), delete the rest
create temp table doomed as select name from storage.objects
  where bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
    and name not in ('72000000-0000-0000-0000-000000000002/teacher-a1-aaaaaaaa.jpg', '72000000-0000-0000-0000-000000000002/teacher-p1-pppppppp.jpg');
select t_is('cleanup finds the rejected and the unused new file', $$select string_agg(name, ',' order by name) from doomed$$,
  '72000000-0000-0000-0000-000000000002/teacher-n1-nnnnnnnn.jpg,72000000-0000-0000-0000-000000000002/teacher-r1-rrrrrrrr.jpg');
select t_is('cleanup deletes them (returning the rows, as the storage API does)',
  $$with d as (delete from storage.objects where bucket_id = 'avatars' and name in (select name from doomed) returning name) select count(*)::text from d$$, '2');
select t_is('the approved and the waiting photo stay', $$select count(*)::text from storage.objects where bucket_id = 'avatars'$$, '2');
reset role;
select t_is('nothing of the mother''s was touched', $$select count(*)::text from storage.objects where name like '72000000-0000-0000-0000-000000000003/%'$$, '1');

\echo '===== 5. the bucket stays public, and the policies say what this suite checks'
select t_is('photos bucket is public (public links keep working without any read policy)', $$select public::text from storage.buckets where id = 'avatars'$$, 'true');
select t_is('exactly one read policy on storage.objects: the owner-only one, for signed-in users',
  $$select string_agg(policyname || ' ' || array_to_string(roles, ','), '; ') from pg_policies where schemaname = 'storage' and tablename = 'objects' and cmd = 'SELECT'$$,
  'avatars: read own authenticated');
select t_is('no read policy open to visitors or to everyone (guard for later migrations)',
  $$select count(*)::text from pg_policies where schemaname = 'storage' and tablename = 'objects' and cmd in ('SELECT', 'ALL') and (roles && array['public', 'anon']::name[])$$, '0');
select t_is('the read policy is limited to the owner''s folder',
  $$select (qual like '%foldername%' and qual like '%auth.uid()%')::text from pg_policies where policyname = 'avatars: read own'$$, 'true');
