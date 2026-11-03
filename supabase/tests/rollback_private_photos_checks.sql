-- After the rollback of step A (20261105000000_private_photos): the private-photo policies and functions are gone,
-- admin_review is the previous one again, and on purpose the bucket and profiles.avatar_path stay (no file or data
-- lost). The public photo flow works as before. PASS:/FAIL: lines.
\pset pager off
\pset footer off
set client_min_messages = notice;
insert into auth.users (id, email, raw_user_meta_data) values ('73500000-0000-0000-0000-000000000003','mom@t','{"full_name":"أم يوسف"}');
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
select t_is('no policy mentions photos-private any more', $$select count(*)::text from pg_policies where tablename = 'objects' and (coalesce(qual, '') || coalesce(with_check, '')) like '%photos-private%'$$, '0');
select t_is('the admin policies on the public bucket are gone', $$select count(*)::text from pg_policies where tablename = 'objects' and policyname like 'avatars: admin%'$$, '0');
select t_is('submit_photo and admin_publish_photo are gone', $$select count(*)::text from pg_proc where proname in ('submit_photo', 'admin_publish_photo')$$, '0');
select t_is('admin_review is the previous version (no photo_path handling)', $$select (prosrc like '%photo_path%')::text from pg_proc where proname = 'admin_review'$$, 'false');
select t_is('admin_review still callable by signed-in users (admin check inside)', $$select has_function_privilege('authenticated', 'public.admin_review(text, uuid, boolean, text)', 'execute')::text$$, 'true');
select t_is('kept on purpose: the private bucket (its files are not lost)', $$select count(*)::text from storage.buckets where id = 'photos-private'$$, '1');
select t_is('kept on purpose: profiles.avatar_path', $$select count(*)::text from information_schema.columns where table_name = 'profiles' and column_name = 'avatar_path'$$, '1');
set role authenticated; set request.jwt.claim.sub = '73500000-0000-0000-0000-000000000003';
select t_err('users cannot upload to the private bucket any more', $$insert into storage.objects (bucket_id, name) values ('photos-private', '73500000-0000-0000-0000-000000000003/profile-r1-rrrrrrrr.jpg')$$);
select t_ok('the public flow works as before: upload own', $$insert into storage.objects (bucket_id, name) values ('avatars', '73500000-0000-0000-0000-000000000003/profile-r1-rrrrrrrr.jpg')$$);
select t_ok('…and set it as profile photo', $$update profiles set avatar_url = 'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/73500000-0000-0000-0000-000000000003/profile-r1-rrrrrrrr.jpg' where id = auth.uid()$$);
reset role;
