-- Run by rollback_drill.sh after supabase/rollback/20261103000000_photo_owner_guard.down.sql: the check is gone and
-- writes behave as before the migration (only the app checks the folder). Prints PASS:/FAIL: only.
\pset pager off
set client_min_messages = notice;
select t_is('guard trigger removed from teachers, institutes, profiles',
  $$select count(*)::text from pg_trigger where tgname = 'zz_photo_owner'$$, '0');
select t_is('guard functions removed',
  $$select count(*)::text from pg_proc where proname in ('photo_owner_guard', 'photo_in_folder') and pronamespace = 'public'::regnamespace$$, '0');
insert into auth.users (id, email) values ('72000000-0000-0000-0000-000000000001', 'a@t');
set role authenticated; set request.jwt.claim.sub = '72000000-0000-0000-0000-000000000001';
select t_ok('as before: a link to another folder is accepted by the database again',
  $$update profiles set avatar_url = 'https://abcdefgh.supabase.co/storage/v1/object/public/avatars/someone-else/x.jpg' where id = auth.uid()$$);
select t_err('the older check (Classi storage only) still applies',
  $$update profiles set avatar_url = 'https://evil.example/x.jpg' where id = auth.uid()$$);
reset role;
