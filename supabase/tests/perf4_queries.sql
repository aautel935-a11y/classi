-- Phase 4 measurements on a database loaded with perf_data.sql. Each line: median of 7 runs (ms) and the number
-- of rows the query returns (more than 1000 = Supabase's API would cut it). Run before and after a change:
--   psql ... -d ct_perf -f supabase/tests/perf4_queries.sql
\pset pager off
\pset footer off
\set QUIET on
create schema if not exists perf;
create or replace function perf.bench(p_label text, p_sql text, p_n int default 7) returns text language plpgsql as $$
declare t0 timestamptz; ms numeric[] := '{}'; n bigint;
begin
  execute 'select count(*) from (' || p_sql || ') x' into n;          -- warm-up and row count
  for i in 1..p_n loop
    t0 := clock_timestamp();
    execute 'select count(*) from (' || p_sql || ') x' into n;
    ms := ms || extract(epoch from clock_timestamp() - t0)::numeric * 1000;
  end loop;
  select array_agg(v order by v) into ms from unnest(ms) v;
  return rpad(p_label, 58) || lpad(round(ms[(p_n + 1) / 2], 2)::text, 9) || ' ms ' || lpad(n::text, 8) || ' rows' || case when n > 1000 then '  (> 1000: cut by the API)' else '' end;
end $$;
grant usage on schema perf to anon, authenticated;
grant execute on function perf.bench(text, text, int) to anon, authenticated;

\echo '--- visitor (anon)'
set role anon;
select perf.bench('catalog: active offers with owner and subject', $q$select o.id, t.name, i.name, s.name from offerings o left join teachers t on t.id = o.teacher_id left join institutes i on i.id = o.institute_id left join subjects s on s.id = o.subject_id where o.active order by o.created_at$q$);
select perf.bench('catalog: teachers by rating', $q$select id, name, rating from teachers order by rating desc$q$);
select perf.bench('seats_overview() whole platform', $q$select * from seats_overview()$q$);
reset role;

\echo '--- teacher 1 (account 1)'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
select perf.bench('owner_bookings() dashboard', $q$select * from owner_bookings()$q$);
select perf.bench('owner_payments()', $q$select * from owner_payments()$q$);
select perf.bench('owner_money_summary()', $q$select * from owner_money_summary()$q$);
select perf.bench('owner_waitlist()', $q$select * from owner_waitlist()$q$);
select perf.bench('my_conversations() teacher', $q$select * from my_conversations()$q$);
select perf.bench('my_header_counts() teacher', $q$select * from my_header_counts()$q$);
select perf.bench('teacher_busy 9 days', $q$select * from teacher_busy('00000000-0000-4000-8000-000000100001', now(), now() + interval '9 days')$q$);
reset role;

\echo '--- institute owner 1 (account 601)'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-4000-8000-000000000601';
select perf.bench('owner_bookings() institute', $q$select * from owner_bookings()$q$);
select perf.bench('owner_payments() institute', $q$select * from owner_payments()$q$);
select perf.bench('owner_money_summary() institute', $q$select * from owner_money_summary()$q$);
reset role;

\echo '--- family (account 1000)'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-4000-8000-000000001000';
select perf.bench('schedule: my live bookings', $q$select b.id from bookings b where b.booked_by = auth.uid() and b.status in ('pending','confirmed')$q$);
select perf.bench('my_conversations() family', $q$select * from my_conversations()$q$);
select perf.bench('chat poll: last 100 messages of a conversation', $q$select m.id from messages m where m.conversation_id = (select id from conversations where user_id = auth.uid() limit 1) order by created_at limit 100$q$);
select perf.bench('notifications page (60 newest)', $q$select id from notifications where user_id = auth.uid() order by created_at desc limit 60$q$);
reset role;

drop schema perf cascade;
