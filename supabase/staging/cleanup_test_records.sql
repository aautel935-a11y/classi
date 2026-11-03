-- classi-staging ONLY: deletes the records the hosted test runs left behind, and nothing else. NOT RUN YET.
-- Run in Supabase -> project classi-staging -> SQL Editor, only after approval, and never while a hosted run is going.
-- One transaction: it refuses on any other database (cluster id, 'staging' marker), refuses if the numbers differ from
-- the read-only count shown before approval (set below), and rolls everything back on any error.
-- What counts as a test record (all three conditions):
--   1. created after the staging seed (2026-11-01 03:27:17.053478 UTC), and
--   2. bookings: cancelled/declined, booked by the test parent account, no payment/package/series;
--      messages: sent by the test parent account and carrying a run marker "run-xxxxxx";
--      notifications: the kinds the journeys create (booking_*, message, review_answer, review_needed),
--   3. created inside the time window of a hosted run (the list below), so a record made at any other time is kept.
-- Kept on purpose: the seed (4 bookings, 2 messages), the 3 active bookings, reminders/reports from scheduled jobs,
-- accounts, offers, children, conversations.
begin;
do $guard$ begin
  if (select system_identifier from pg_control_system()) <> 7702070854497379551 then raise exception 'refusing: not the classi-staging database'; end if;
  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then raise exception 'refusing: database not marked staging'; end if;
end $guard$;

create temp table runs (run text, s timestamptz, e timestamptz) on commit drop;
insert into runs values
 ('41488423131', '2026-11-03T08:10:22Z', '2026-11-03T08:19:00Z'),
 ('41708730798', '2026-11-03T20:01:41Z', '2026-11-03T20:07:26Z'),
 ('41716623354', '2026-11-03T20:52:54Z', '2026-11-03T21:01:58Z'),
 ('41721336243', '2026-11-03T21:23:17Z', '2026-11-03T21:38:12Z'),
 ('41730673103', '2026-11-03T22:24:00Z', '2026-11-03T22:42:00Z');

create temp table doomed_bookings on commit drop as
  select b.id from public.bookings b
   where b.created_at > '2026-11-01 03:27:17.053478+00' and b.status in ('cancelled', 'declined')
     and b.booked_by = '00000000-0000-4000-8000-000000000003'
     and b.paid_at is null and b.package_id is null and b.series_id is null
     and exists (select 1 from runs where b.created_at between runs.s and runs.e);
create temp table doomed_messages on commit drop as
  select m.id from public.messages m
   where m.created_at > '2026-11-01 03:27:17.053478+00' and m.body ~ 'run-[0-9a-z]{6,}'
     and m.sender_id = '00000000-0000-4000-8000-000000000003'
     and exists (select 1 from runs where m.created_at between runs.s and runs.e);
create temp table doomed_notifications on commit drop as
  select n.id from public.notifications n
   where n.created_at > '2026-11-01 03:27:17.053478+00'
     and n.kind::text in ('booking_answer', 'booking_new', 'booking_request', 'booking_withdrawn', 'message', 'review_answer', 'review_needed')
     and exists (select 1 from runs where n.created_at between runs.s and runs.e);

-- the read-only count shown before approval (update these three numbers to that count; any difference stops here)
do $check$ declare b int; m int; n int; begin
  select count(*) into b from doomed_bookings; select count(*) into m from doomed_messages; select count(*) into n from doomed_notifications;
  if (b, m, n) <> (20, 8, 121) then raise exception 'refusing: counts changed (bookings %, messages %, notifications %)', b, m, n; end if;
  -- nothing may still point at these records (attendance, reviews, lesson reports, SMS log)
  if exists (select 1 from public.attendance where booking_id in (select id from doomed_bookings))
     or exists (select 1 from public.reviews where booking_id in (select id from doomed_bookings))
     or exists (select 1 from public.lesson_reports where booking_id in (select id from doomed_bookings))
     or exists (select 1 from public.sms_log where notification_id in (select id from doomed_notifications)) then
    raise exception 'refusing: another record still points at a test record';
  end if;
end $check$;

delete from public.notifications where id in (select id from doomed_notifications);
delete from public.messages where id in (select id from doomed_messages);
delete from public.bookings where id in (select id from doomed_bookings);

-- what must be left
do $after$ begin
  if (select count(*) from public.bookings where status in ('pending', 'confirmed')) <> 3 then raise exception 'refusing: active bookings changed'; end if;
  if (select count(*) from public.bookings where created_at <= '2026-11-01 03:27:17.053478+00') <> 4 then raise exception 'refusing: seed bookings changed'; end if;
end $after$;
commit;
-- expected result: "Success. No rows returned". Afterwards: bookings 4, messages 2, notifications 15.
