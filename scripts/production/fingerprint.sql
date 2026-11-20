-- READ-ONLY fingerprint of the public schema, comparable between Classi production and a local database built
-- from the same migrations. Run in a read-only transaction (Supabase SQL Editor or psql); changes nothing.
-- Function bodies are compared WITHOUT "--" comments and whitespace: production's bodies were applied with comments
-- stripped (20/11/2026 check), so a raw md5 differs for 12 functions whose code is identical.
-- Every ordering uses collate "C": the database's default collation differs between servers, and with it the order.
-- Test-only helpers of the local stub (t_*, test_*) are left out. Also covers storage policies and buckets (the photo
-- migrations change them) and app_private functions.
begin transaction read only;
with f as (
  select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|'
         || md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) || '|' || p.prosecdef || '|'
         || coalesce(array_to_string(p.proconfig, ','), '-') || '|anon=' || has_function_privilege('anon', p.oid, 'execute')
         || '|auth=' || has_function_privilege('authenticated', p.oid, 'execute') x
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.proname !~ '^(t|test)_'
)
select 'functions' part, count(*) n, md5(string_agg(x, E'\n' order by x collate "C")) fp from f
union all
select 'columns', count(*), md5(string_agg(table_name || '.' || column_name || ':' || data_type, E'\n' order by table_name collate "C", column_name collate "C"))
from information_schema.columns where table_schema = 'public'
union all
select 'policies', count(*), md5(string_agg(tablename || '.' || policyname || ':' || cmd || ':' || array_to_string(roles, ','), E'\n' order by tablename collate "C", policyname collate "C"))
from pg_policies where schemaname = 'public'
union all
select 'triggers', count(*), md5(string_agg(tgrelid::regclass || '.' || tgname, E'\n' order by tgrelid::regclass::text collate "C", tgname collate "C"))
from pg_trigger t join pg_class c on c.oid = t.tgrelid where not t.tgisinternal and c.relnamespace = 'public'::regnamespace
union all
select 'rls_off', count(*), '-' from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and not c.relrowsecurity
union all
select 'storage', (select count(*) from pg_policies where schemaname = 'storage'),
  md5(coalesce((select string_agg(tablename || '.' || policyname || ':' || cmd || ':' || array_to_string(roles, ','), E'\n' order by tablename collate "C", policyname collate "C")
                from pg_policies where schemaname = 'storage'), '') || '#'
      || coalesce((select string_agg(id || ':' || public, ',' order by id collate "C") from storage.buckets), ''))
union all
select 'app_private', count(*), coalesce(md5(string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|'
       || md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) || '|' || p.prosecdef, E'\n' order by p.proname collate "C", pg_get_function_identity_arguments(p.oid) collate "C")), '-')
from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app_private'
order by 1;
commit;
