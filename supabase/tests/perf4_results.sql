-- Fingerprints (row count + md5 of all rows, sorted) of the functions phase 4 rewrites, per account, saved under
-- a label. Equal fingerprints before and after = identical results.  psql ... -v label=before -f perf4_results.sql
\set QUIET on
create table if not exists perf_res (label text, who text, fn text, n bigint, md5 text);
delete from perf_res where label = :'label';
create temp table perf_res_stage (label text, who text, fn text, n bigint, md5 text);
grant all on perf_res_stage to anon, authenticated;
create or replace function perf_fp(p_label text, p_who text) returns void language plpgsql security invoker as $$
declare f text; q text;
begin
  for f, q in values
    ('owner_bookings', 'select * from owner_bookings()'),
    ('owner_bookings(offer)', 'select * from owner_bookings((select id from offerings where teacher_id = my_teacher_id() or institute_id in (select id from institutes where owner_id = auth.uid()) order by id limit 1))'),
    ('owner_payments', 'select * from owner_payments()'),
    ('owner_money_summary', 'select * from owner_money_summary()'),
    ('owner_waitlist', 'select * from owner_waitlist()'),
    ('my_conversations', 'select * from my_conversations()'),
    ('seats_overview', 'select * from seats_overview() order by 1, 2 nulls first')
  loop
    execute format('insert into perf_res_stage select %L, %L, %L, count(*), md5(string_agg(x::text, %L order by x::text)) from (select t as x from (%s) t) s',
                   p_label, p_who, f, '|', q);
  end loop;
end $$;
grant execute on function perf_fp(text, text) to anon, authenticated;
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001'; select perf_fp(:'label', 'teacher 1');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000002'; select perf_fp(:'label', 'teacher 2');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000050'; select perf_fp(:'label', 'unverified teacher 50');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000071'; select perf_fp(:'label', 'teacher 71 (also course teacher)');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000601'; select perf_fp(:'label', 'institute owner 601');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000620'; select perf_fp(:'label', 'unverified institute 620');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000001000'; select perf_fp(:'label', 'family 1000');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000005000'; select perf_fp(:'label', 'family 5000');
reset role;
insert into perf_res select * from perf_res_stage;
select who, fn, n from perf_res where label = :'label' order by 1, 2;
