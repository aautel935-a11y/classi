-- classi-staging ONLY: undoes supabase/staging/cleanup_test_records.sql by putting back the exact rows it deleted,
-- from its backup tables (cleanup_backup.*_20261104). One transaction; refuses on any other database, if the backup is
-- missing or incomplete, or if any of those rows already exists again. Afterwards the backup tables stay (drop them
-- separately once no longer needed).
begin;
do $guard$ begin
  if (select system_identifier from pg_control_system()) <> 7702070854497379551 then raise exception 'refusing: not the classi-staging database'; end if;
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then raise exception 'refusing: database not marked staging'; end if;
  if to_regclass('cleanup_backup.bookings_20261104') is null or to_regclass('cleanup_backup.messages_20261104') is null
     or to_regclass('cleanup_backup.notifications_20261104') is null then raise exception 'refusing: backup tables not found'; end if;
  if (select count(*) from cleanup_backup.bookings_20261104) <> 20 or (select count(*) from cleanup_backup.messages_20261104) <> 8
     or (select count(*) from cleanup_backup.notifications_20261104) <> 121 then raise exception 'refusing: backup incomplete'; end if;
  if exists (select 1 from public.bookings where id in (select id from cleanup_backup.bookings_20261104))
     or exists (select 1 from public.messages where id in (select id from cleanup_backup.messages_20261104))
     or exists (select 1 from public.notifications where id in (select id from cleanup_backup.notifications_20261104)) then
    raise exception 'refusing: some rows are already back';
  end if;
end $guard$;
-- the app's own triggers (notifications, booking rules) must not fire for restored rows; foreign keys stay enforced
-- (they are system triggers, untouched by "disable trigger user"). Re-enabled before commit.
alter table public.bookings disable trigger user;
alter table public.messages disable trigger user;
alter table public.notifications disable trigger user;
insert into public.bookings select * from cleanup_backup.bookings_20261104;
insert into public.messages select * from cleanup_backup.messages_20261104;
insert into public.notifications select * from cleanup_backup.notifications_20261104;
alter table public.bookings enable trigger user;
alter table public.messages enable trigger user;
alter table public.notifications enable trigger user;
commit;
-- expected result: "Success. No rows returned". Afterwards: bookings 24, messages 10, notifications 136 (as before).
