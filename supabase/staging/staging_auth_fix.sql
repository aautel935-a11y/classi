-- STAGING ONLY. Makes the five manual test accounts complete Supabase Auth users, so they can sign in through the
-- normal login screen with their test numbers: audience/role "authenticated" (the role in their session token) and
-- a "phone" identity. Idempotent: safe to run again. Only touches the five fixed ids; refuses a non-staging database.
do $$
declare has_identities boolean := to_regclass('auth.identities') is not null;
begin
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then
    raise exception 'refusing: this database is not marked staging';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'aud') then
    execute $q$update auth.users set aud = 'authenticated', role = 'authenticated',
                 instance_id = coalesce(instance_id, '00000000-0000-0000-0000-000000000000')
               where id in ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002',
                            '00000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000004',
                            '00000000-0000-4000-8000-000000000005')$q$;
  end if;
  if has_identities then
    execute $q$insert into auth.identities (provider_id, user_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
               select u.id::text, u.id, 'phone',
                      jsonb_build_object('sub', u.id::text, 'phone', u.phone, 'phone_verified', true, 'email_verified', false),
                      null, now(), now()
                 from auth.users u
                where u.id in ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002',
                               '00000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000004',
                               '00000000-0000-4000-8000-000000000005')
                  and not exists (select 1 from auth.identities i where i.user_id = u.id and i.provider = 'phone')$q$;
  end if;
end $$;
