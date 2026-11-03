-- What the hosted staging suite (tests/staging) may change, in a stable order. The CI dry run prints this before and
-- after the suite and requires both to be identical: every change a test makes must be undone by that test.
-- Expected leftovers are deliberately NOT listed: cancelled/declined bookings, messages, notifications, and the
-- one-way flag teachers.hours_confirmed_at (set the first time hours are saved; not compared, reported by S8).
with samer as (select id from public.teachers where name = 'سامر مصاروة')
select line from (
  select 1 o, 'availability ' || weekday || ' ' || to_char(start_time, 'HH24:MI') || '-' || to_char(end_time, 'HH24:MI') line
    from public.availability where teacher_id = (select id from samer)
  union all select 2, 'break ' || buffer_minutes || ' | photo ' || coalesce(photo_url, '-') || ' | pending ' || coalesce(pending_changes::text, '-')
    from public.teachers where id = (select id from samer)
  union all select 3, 'offer ' || title || ' | instant ' || auto_confirm || ' | active ' || coalesce(active::text, '-') || ' | review ' || review_status
                      || ' | pending ' || coalesce(pending_changes::text, '-')
    from public.offerings where teacher_id = (select id from samer)
  union all select 4, 'offers in total ' || count(*) from public.offerings
  union all select 5, 'offer links in total ' || count(*) from public.offering_links
  union all select 6, 'profile photo ' || right(id::text, 1) || ' ' || coalesce(avatar_url, '-')
    from public.profiles where id::text like '00000000-0000-4000-8000-00000000000_'
  union all select 7, 'photo files ' || count(*) from storage.objects where bucket_id = 'avatars'
  union all select 8, 'children ' || count(*) from public.children
  union all select 9, 'pending or confirmed bookings ' || count(*) from public.bookings where status in ('pending', 'confirmed')
) x order by o, line;
