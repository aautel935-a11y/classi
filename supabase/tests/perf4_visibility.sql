-- Who sees which offers (and teachers / institutes), saved under a label, to prove a change keeps visibility identical.
--   psql ... -v label=before -f perf4_visibility.sql   (then label=after, then compare with the last query)
\set QUIET on
create table if not exists perf_vis (label text, who text, tbl text, id uuid);
delete from perf_vis where label = :'label';
create or replace function perf_snap(p_label text, p_who text) returns void language plpgsql security invoker as $$
begin
  insert into perf_vis_stage select p_label, p_who, 'offerings', id from offerings;
  insert into perf_vis_stage select p_label, p_who, 'teachers', id from teachers;
  insert into perf_vis_stage select p_label, p_who, 'institutes', id from institutes;
end $$;
create temp table perf_vis_stage (label text, who text, tbl text, id uuid);
grant all on perf_vis_stage to anon, authenticated;
grant execute on function perf_snap(text, text) to anon, authenticated;
set role anon; select perf_snap(:'label', 'visitor'); reset role;
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000001000'; select perf_snap(:'label', 'family 1000');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000050'; select perf_snap(:'label', 'unverified teacher 50');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000070'; select perf_snap(:'label', 'suspended teacher 70');
set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000620'; select perf_snap(:'label', 'unverified institute owner 620');
reset role;
insert into perf_vis select * from perf_vis_stage;
select label, who, tbl, count(*) from perf_vis where label = :'label' group by 1, 2, 3 order by 2, 3;
