-- After the rollback of step B (20261105010000_private_photos_enforce): users may upload to their own public folder
-- and set public photo links again (as before private photos), and the private flow of step A still works.
-- PASS:/FAIL: lines.
\pset pager off
\pset footer off
set client_min_messages = notice;
insert into auth.users (id, email, raw_user_meta_data) values ('74500000-0000-0000-0000-000000000003','mom@t','{"full_name":"أم يوسف"}');
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
select t_is('the guard trigger and function are gone', $$select count(*)::text from pg_proc where proname = 'photo_publish_guard'$$, '0');
select t_is('upload own / replace own are back on the public bucket', $$select string_agg(policyname, ', ' order by policyname) from pg_policies where tablename = 'objects' and policyname in ('avatars: upload own', 'avatars: replace own')$$, 'avatars: replace own, avatars: upload own');
set role authenticated; set request.jwt.claim.sub = '74500000-0000-0000-0000-000000000003';
select t_ok('a user uploads into her own public folder again', $$insert into storage.objects (bucket_id, name) values ('avatars', '74500000-0000-0000-0000-000000000003/profile-r1-rrrrrrrr.jpg')$$);
select t_ok('…and sets it as her public profile photo again', $$update profiles set avatar_url = 'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/74500000-0000-0000-0000-000000000003/profile-r1-rrrrrrrr.jpg' where id = auth.uid()$$);
select t_err('not into someone else''s folder', $$insert into storage.objects (bucket_id, name) values ('avatars', '74500000-0000-0000-0000-000000000001/profile-r1-rrrrrrrr.jpg')$$);
select t_ok('the private flow (step A) still works: upload', $$insert into storage.objects (bucket_id, name) values ('photos-private', '74500000-0000-0000-0000-000000000003/profile-r2-rrrrrrrr.jpg')$$);
select t_ok('the private flow (step A) still works: submit', $$select submit_photo('profile', '74500000-0000-0000-0000-000000000003/profile-r2-rrrrrrrr.jpg')$$);
reset role;
