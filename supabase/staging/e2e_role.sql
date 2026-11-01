-- STAGING ONLY. Least-privilege database access for the automated browser tests against classi-staging.
--
-- The role e2e_staging gets NO table privileges and NO special attributes (no SUPERUSER, CREATEROLE, CREATEDB,
-- REPLICATION or BYPASSRLS). It can only call the e2e_* functions below. Each function:
--   * refuses to run unless this database is marked staging (app_secrets deploy_env = 'staging');
--   * acts only on TEST accounts: phone 97252[12]xxxxxx (the numbers tests/e2e/helpers.mjs phoneFor() makes),
--     signed up by phone (no e-mail) within the last 24 hours. The five manual test accounts (9725000000xx), the
--     demo listings and any other account are refused;
--   * returns only what the test checks (an id, a code, a count, a status), never secrets or personal data.
-- The role is created NOLOGIN. The owner enables it in the Supabase SQL editor (never in chat):
--   alter role e2e_staging with login password '<generated, letters and digits>';
-- and stores postgresql://e2e_staging.nfipmylyahhogykikuqo:<password>@<pooler host>:5432/postgres as the GitHub
-- Environment "staging" secret STAGING_E2E_DB_URL. To lock it again: alter role e2e_staging nologin;
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then
    raise exception 'refusing: this database is not marked staging';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'e2e_staging') then
    create role e2e_staging nologin nosuperuser nocreaterole nocreatedb noreplication nobypassrls noinherit connection limit 3;
  end if;
end $$;
alter role e2e_staging nosuperuser nocreaterole nocreatedb noreplication nobypassrls noinherit connection limit 3;
alter role e2e_staging set statement_timeout = '15s';
alter role e2e_staging set idle_in_transaction_session_timeout = '30s';
alter role e2e_staging set search_path = '';

-- Private schema for the test helpers: nothing else lives here, and only e2e_staging may use it.
create schema if not exists e2e;
revoke all on schema e2e from public, anon, authenticated, service_role;
grant usage on schema e2e to e2e_staging;

-- Internal checks (not callable by anyone but the functions below, which run as their owner).
create or replace function e2e._staging() returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then
    raise exception 'e2e helpers run only on the staging database';
  end if;
end $$;
create or replace function e2e._test_phone(p_digits text) returns boolean language sql immutable set search_path = '' as $$
  select coalesce(p_digits, '') ~ '^97252[12][0-9]{6}$'
$$;
create or replace function e2e._test_user(p_user uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from auth.users u
                  where u.id = p_user and e2e._test_phone(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g'))
                    and u.email is null and u.created_at > now() - interval '24 hours')
$$;
create or replace function e2e._test_teacher(p_teacher uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.teachers t where t.id = p_teacher and e2e._test_user(t.user_id))
$$;

-- Sign-in codes (only for test numbers; nothing else is ever in reach)
create or replace function e2e.otp(p_digits text) returns text language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not e2e._test_phone(p_digits) then raise exception 'not a test number'; end if;
  return (select o.otp from public.otp_outbox o where regexp_replace(o.phone, '\D', '', 'g') = p_digits order by o.created_at desc limit 1);
end $$;
create or replace function e2e.otp_count(p_digits text) returns int language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not e2e._test_phone(p_digits) then raise exception 'not a test number'; end if;
  return (select count(*)::int from public.otp_outbox o where regexp_replace(o.phone, '\D', '', 'g') = p_digits);
end $$;

-- Ids and results of the test's own accounts
create or replace function e2e.user_id(p_digits text) returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform e2e._staging();
  if not e2e._test_phone(p_digits) then raise exception 'not a test number'; end if;
  select u.id into v from auth.users u where regexp_replace(coalesce(u.phone, ''), '\D', '', 'g') = p_digits limit 1;
  if v is not null and not e2e._test_user(v) then raise exception 'not a test account'; end if;
  return v;
end $$;
create or replace function e2e.teacher_id(p_user uuid) returns uuid language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not e2e._test_user(p_user) then raise exception 'not a test account'; end if;
  return (select t.id from public.teachers t where t.user_id = p_user limit 1);
end $$;
create or replace function e2e.latest_offer(p_teacher uuid) returns uuid language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not e2e._test_teacher(p_teacher) then raise exception 'not a test teacher'; end if;
  return (select o.id from public.offerings o where o.teacher_id = p_teacher order by o.created_at desc limit 1);
end $$;
create or replace function e2e.offer_bookings(p_offer uuid) returns table (status text, for_child boolean)
language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not exists (select 1 from public.offerings o where o.id = p_offer and e2e._test_teacher(o.teacher_id)) then
    raise exception 'not a test offer';
  end if;
  return query select b.status::text, b.child_id is not null from public.bookings b where b.offering_id = p_offer order by b.created_at;
end $$;
create or replace function e2e.unread_count(p_user uuid) returns int language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not e2e._test_user(p_user) then raise exception 'not a test account'; end if;
  return (select count(*)::int from public.notifications n where n.user_id = p_user and n.read_at is null);
end $$;

-- The admin's part, for the test's own accounts only
create or replace function e2e.verify_teacher(p_teacher uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not e2e._test_teacher(p_teacher) then raise exception 'not a test teacher'; end if;
  update public.teachers set verify = 'verified' where id = p_teacher;
end $$;
create or replace function e2e.approve_offer(p_offer uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not exists (select 1 from public.offerings o where o.id = p_offer and e2e._test_teacher(o.teacher_id)) then
    raise exception 'not a test offer';
  end if;
  update public.offerings set review_status = 'approved' where id = p_offer;
end $$;
create or replace function e2e.make_admin(p_user uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not e2e._test_user(p_user) then raise exception 'not a test account'; end if;
  update public.profiles set roles = array['admin']::public.app_role[] where id = p_user;
end $$;

-- Public facts (what any visitor already sees) and the demo listing used by the right-to-left text test
create or replace function e2e.public_offer(p_approved_only boolean) returns uuid language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  return (select o.id from public.offerings o where o.type = 'private' and o.active
            and (not p_approved_only or o.review_status = 'approved') order by o.created_at limit 1);
end $$;
create or replace function e2e.demo_teacher() returns uuid language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  return (select t.id from public.teachers t where t.verify = 'verified' and t.user_id is null order by t.name limit 1);
end $$;
create or replace function e2e.set_demo_bio(p_teacher uuid, p_bio text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform e2e._staging();
  if not exists (select 1 from public.teachers t where t.id = p_teacher and t.user_id is null) then
    raise exception 'only demo listings (no account) may be edited';
  end if;
  update public.teachers set bio = left(p_bio, 500) where id = p_teacher;
end $$;

-- Execute rights: the callable helpers to e2e_staging only; the internal checks to nobody.
revoke all on all functions in schema e2e from public, anon, authenticated, service_role;
grant execute on function e2e.otp(text), e2e.otp_count(text), e2e.user_id(text), e2e.teacher_id(uuid),
  e2e.latest_offer(uuid), e2e.offer_bookings(uuid), e2e.unread_count(uuid), e2e.verify_teacher(uuid),
  e2e.approve_offer(uuid), e2e.make_admin(uuid), e2e.public_offer(boolean), e2e.demo_teacher(),
  e2e.set_demo_bio(uuid, text) to e2e_staging;
commit;
