-- STAGING ONLY. A least-privilege database role for the automated browser tests against staging, instead of the
-- full "postgres" connection. The tests only need to: read sign-in codes, read a few rows to check results, and
-- play the admin's part in three places (verify a teacher, approve an offer, make a test account admin).
-- Created NOLOGIN: the owner turns it on by setting a password in the Supabase SQL editor (never in chat):
--   alter role e2e_staging with login password '<generated, letters and digits>';
-- and stores postgresql://e2e_staging.nfipmylyahhogykikuqo:<password>@<pooler host>:5432/postgres as the GitHub
-- Environment "staging" secret STAGING_E2E_DB_URL. Refuses to run on a database not marked staging.
do $$ begin
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then
    raise exception 'refusing: this database is not marked staging';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'e2e_staging') then
    create role e2e_staging nologin bypassrls connection limit 5;
  end if;
end $$;
alter role e2e_staging set statement_timeout = '30s';

grant usage on schema public to e2e_staging;
-- reading (the tests check what the app did)
grant select on public.otp_outbox, public.notifications, public.bookings, public.offerings, public.teachers to e2e_staging;
-- auth.users is not readable directly (the role gets no access to the auth schema); one narrow lookup instead:
create or replace function public.e2e_user_id_by_phone(p_phone text) returns uuid
language sql stable security definer set search_path = '' as $$
  select id from auth.users where phone in (p_phone, '+' || p_phone) limit 1
$$;
revoke all on function public.e2e_user_id_by_phone(text) from public, anon, authenticated;
grant execute on function public.e2e_user_id_by_phone(text) to e2e_staging;
grant select (id) on public.profiles to e2e_staging;
-- the admin's part (only these columns)
grant update (verify, bio) on public.teachers to e2e_staging;
grant update (review_status) on public.offerings to e2e_staging;
grant update (roles) on public.profiles to e2e_staging;
-- nothing else: no secrets, no messages, no children, no payments, no delete, no DDL
revoke all on public.app_secrets from e2e_staging;
