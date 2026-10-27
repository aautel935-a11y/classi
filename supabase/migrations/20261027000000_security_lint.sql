-- Classi: Supabase security advisor clean-up.
--  · extend_recurring is maintenance only (runs nightly inside the database), not callable from the site
--  · every public function gets a fixed search_path (advisor: "Function Search Path Mutable")
revoke execute on function public.extend_recurring() from anon, authenticated, public;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')  -- skip extension functions
  loop
    execute format('alter function %s set search_path = public', f.sig);
  end loop;
end $$;
