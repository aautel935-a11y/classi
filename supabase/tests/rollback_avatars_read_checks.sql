-- After the rollback of 20261104000000_avatars_read_own: the old behaviour is back exactly (everyone can list the
-- photos bucket), and nothing else changed (upload and delete still own-folder only). PASS:/FAIL: lines.
\pset pager off
\pset footer off
set client_min_messages = notice;
insert into auth.users (id, email, raw_user_meta_data) values
 ('72100000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('72100000-0000-0000-0000-000000000003','mom@t','{"full_name":"أم يوسف"}');
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
insert into storage.objects (bucket_id, name) values ('avatars', '72100000-0000-0000-0000-000000000002/teacher-a1-aaaaaaaa.jpg');

select t_is('the old policy is back, for everyone', $$select string_agg(policyname || ' ' || array_to_string(roles, ','), '; ') from pg_policies where schemaname = 'storage' and tablename = 'objects' and cmd = 'SELECT' and qual like '%''avatars''%' and qual not like '%is_admin%'$$, 'avatars: read public');
select t_is('the owner-only policy is gone', $$select count(*)::text from pg_policies where policyname = 'avatars: read own'$$, '0');
set role anon; reset request.jwt.claim.sub;
select t_is('a visitor lists the bucket again (old behaviour)', $$select count(*)::text from storage.objects where bucket_id = 'avatars'$$, '1');
reset role;
set role authenticated; set request.jwt.claim.sub = '72100000-0000-0000-0000-000000000003';
select t_is('another user lists Samer''s folder again (old behaviour)', $$select count(*)::text from storage.objects where name like '72100000-0000-0000-0000-000000000002/%'$$, '1');
select t_err('upload into someone else''s folder is still refused', $$insert into storage.objects (bucket_id, name) values ('avatars', '72100000-0000-0000-0000-000000000002/x-1-aaaaaaaa.jpg')$$);
delete from storage.objects where name like '72100000-0000-0000-0000-000000000002/%';
reset role;
select t_is('delete of someone else''s file is still refused', $$select count(*)::text from storage.objects where name like '72100000-0000-0000-0000-000000000002/%'$$, '1');
