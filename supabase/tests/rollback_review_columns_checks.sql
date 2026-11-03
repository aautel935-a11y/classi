-- Run by rollback_drill.sh after supabase/rollback/20261103010000_review_columns_owner_only.down.sql: signed-in users
-- read every column again (the state before), visitors stay limited, my_review_state() is kept on purpose.
\pset pager off
set client_min_messages = notice;
insert into auth.users (id, email) values ('72000000-0000-0000-0000-000000000002', 'b@t');
set role authenticated; set request.jwt.claim.sub = '72000000-0000-0000-0000-000000000002';
select t_ok('as before: signed-in users read pending_changes', $$select pending_changes, review_note from teachers limit 1$$);
select t_ok('as before: select * works for signed-in users', $$select * from offerings limit 1$$);
select t_ok('my_review_state is kept (the app version that uses it keeps working)', $$select * from my_review_state()$$);
reset role;
set role anon; reset request.jwt.claim.sub;
select t_err('visitors stay limited (SEC-06 unchanged)', $$select pending_changes from teachers limit 1$$);
reset role;
