-- Classi: lesson reminders and phone notifications.
--  · students/parents: 24 hours and 1 hour before every lesson or meeting
--  · teachers: 1 hour before each lesson or group/course meeting
--  · important notifications (reminders, answers, changes, free seats) are also
--    sent to the phone as push notifications, by /api/push/dispatch.
-- The database runs the schedule itself (pg_cron every few minutes) and wakes the
-- dispatcher through pg_net, so nothing depends on Vercel's once-a-day cron.

-- ================= storage =================
-- Server-only values (push keys, dispatcher secret). No policies: only security-definer code reads it.
create table if not exists public.app_secrets (key text primary key, value text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

create table if not exists public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
create policy "see own push" on public.push_subscriptions for select using (user_id = auth.uid());
grant select on public.push_subscriptions to authenticated;

-- One row per reminder already sent, so each goes out once.
create table if not exists public.reminder_log (key text primary key, sent_at timestamptz not null default now());
alter table public.reminder_log enable row level security;

alter table public.notifications add column if not exists want_push boolean not null default false;
alter table public.notifications add column if not exists pushed_at timestamptz;
create index if not exists notifications_push_queue on public.notifications (created_at) where want_push and pushed_at is null;

alter table public.profiles add column if not exists email_reminders boolean not null default true;

-- Which notifications are worth a phone buzz.
create or replace function public.notifications_mark_push() returns trigger
language plpgsql as $$
begin
  new.want_push := new.kind in ('reminder','reminder_soon','booking_answer','booking_request','booking_new','booking_cancelled',
                                'schedule_changed','waitlist_open','waitlist_answer','waitlist_join','verified','message');
  return new;
end $$;
drop trigger if exists notifications_mark_push on public.notifications;
create trigger notifications_mark_push before insert on public.notifications
  for each row execute function public.notifications_mark_push();

-- ================= subscriptions (from the browser) =================
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'سجّل الدخول أولاً'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or length(p_p256dh) > 200 or length(p_auth) > 100 then
    raise exception 'اشتراك غير صالح';
  end if;
  insert into push_subscriptions (user_id, endpoint, p256dh, auth) values (auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
end $$;

create or replace function public.remove_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid()
$$;

-- ================= reminders =================
create or replace function public.hhmm(ts timestamptz) returns text
language sql immutable as $$ select to_char(ts at time zone 'Asia/Jerusalem', 'HH24:MI') $$;

-- Finds lessons coming up and writes the reminders that are due. Safe to run any time.
create or replace function public.send_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0; v_key text;
begin
  -- Every upcoming confirmed lesson for the student side:
  -- private (booking time), group (its meeting), course (each meeting of the course).
  for r in
    with occ as (
      select b.id booking_id, null::uuid session_id, b.starts_at, b.booked_by, b.child_id, b.offering_id, b.mode
        from bookings b where b.status = 'confirmed' and b.starts_at is not null
         and b.starts_at > now() and b.starts_at <= now() + interval '24 hours'
      union all
      select b.id, s.id, s.starts_at, b.booked_by, b.child_id, b.offering_id, b.mode
        from bookings b join sessions s on s.id = b.session_id
       where b.status = 'confirmed' and not s.cancelled and s.starts_at > now() and s.starts_at <= now() + interval '24 hours'
      union all
      select b.id, s.id, s.starts_at, b.booked_by, b.child_id, b.offering_id, b.mode
        from bookings b join offerings o on o.id = b.offering_id and o.type = 'course'
        join sessions s on s.offering_id = o.id
       where b.status = 'confirmed' and b.session_id is null and not s.cancelled
         and s.starts_at > now() and s.starts_at <= now() + interval '24 hours'
    )
    select occ.*, o.title, o.type, coalesce(t.name, i.name) owner_name, c.name child_name,
           case when occ.starts_at <= now() + interval '70 minutes' then 'soon' else 'day' end slot
      from occ join offerings o on o.id = occ.offering_id
      left join teachers t on t.id = o.teacher_id
      left join institutes i on i.id = o.institute_id
      left join children c on c.id = occ.child_id
     where is_active_user(occ.booked_by)
       -- the day-before reminder only when the lesson is roughly a day away (not for last-minute bookings)
       and (occ.starts_at <= now() + interval '70 minutes' or occ.starts_at > now() + interval '20 hours')
  loop
    v_key := format('s:%s:%s:%s', r.booking_id, coalesce(r.session_id::text, '-'), r.slot);
    insert into reminder_log (key) values (v_key) on conflict do nothing;
    if not found then continue; end if;
    insert into notifications (user_id, kind, body, link) values (
      r.booked_by,
      case r.slot when 'soon' then 'reminder_soon' else 'reminder' end,
      case r.slot
        when 'soon' then format('بعد قليل، الساعة %s: %s%s%s', hhmm(r.starts_at), r.title,
                                coalesce(' لـ' || r.child_name, ''),
                                case when r.mode = 'online' then '. رابط اللقاء في جدولك.' else '.' end)
        else format('تذكير: %s الساعة %s، %s مع %s%s.',
                    case when (r.starts_at at time zone 'Asia/Jerusalem')::date = (now() at time zone 'Asia/Jerusalem')::date then 'اليوم' else 'غداً' end,
                    hhmm(r.starts_at), r.title, r.owner_name, coalesce(' لـ' || r.child_name, ''))
      end,
      '/schedule');
    v_n := v_n + 1;
  end loop;

  -- Teachers: one reminder an hour before each private lesson, and each group/course meeting.
  for r in
    select 'b' || b.id::text ref, b.starts_at, t.user_id, o.title,
           coalesce(c.name, p.full_name, 'طالب') who, 1 n, b.mode
      from bookings b join offerings o on o.id = b.offering_id join teachers t on t.id = o.teacher_id
      left join children c on c.id = b.child_id left join profiles p on p.id = b.booked_by
     where o.type = 'private' and b.status = 'confirmed' and t.user_id is not null
       and b.starts_at > now() and b.starts_at <= now() + interval '70 minutes'
    union all
    select 'm' || s.id::text, s.starts_at, t.user_id, o.title, null,
           (select count(*)::int from bookings b where b.status = 'confirmed'
              and ((o.type = 'group' and b.session_id = s.id) or (o.type = 'course' and b.offering_id = o.id and b.session_id is null))),
           null
      from sessions s join offerings o on o.id = s.offering_id
      join teachers t on t.id = coalesce(o.course_teacher_id, o.teacher_id)
     where not s.cancelled and t.user_id is not null
       and s.starts_at > now() and s.starts_at <= now() + interval '70 minutes'
  loop
    if r.n = 0 then continue; end if;
    v_key := format('t:%s:%s', r.ref, r.user_id);
    insert into reminder_log (key) values (v_key) on conflict do nothing;
    if not found then continue; end if;
    insert into notifications (user_id, kind, body, link) values (
      r.user_id, 'reminder_soon',
      case when r.who is not null then format('بعد قليل، الساعة %s: حصة مع %s (%s)%s', hhmm(r.starts_at), r.who, r.title,
                                              case when r.mode = 'online' then '، أونلاين' else '' end)
           else format('بعد قليل، الساعة %s: %s (عدد المسجّلين: %s)', hhmm(r.starts_at), r.title, r.n) end,
      '/teach');
    v_n := v_n + 1;
  end loop;

  delete from reminder_log where sent_at < now() - interval '3 days';
  return v_n;
end $$;

-- ================= delivery (called by /api/push/dispatch with the secret) =================
create or replace function public.claim_push(p_secret text, p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_items jsonb;
begin
  if p_secret is null or p_secret is distinct from (select value from app_secrets where key = 'dispatch_secret') then
    raise exception 'unauthorized';
  end if;
  with picked as (
    update notifications n set pushed_at = now()
     where n.id in (select id from notifications where want_push and pushed_at is null
                     and created_at > now() - interval '2 hours'
                     order by created_at limit least(greatest(p_limit, 1), 500) for update skip locked)
    returning n.id, n.user_id, n.kind, n.body, n.link
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', pk.id, 'kind', pk.kind, 'body', pk.body, 'link', pk.link,
           'email', case when pk.kind = 'reminder' and pr.email_reminders then u.email end,
           'name', pr.full_name,
           'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth)))
                               from push_subscriptions s where s.user_id = pk.user_id), '[]'::jsonb))), '[]'::jsonb)
    into v_items
    from picked pk join profiles pr on pr.id = pk.user_id left join auth.users u on u.id = pk.user_id;
  -- Old undelivered rows (e.g. while the dispatcher was down) are dropped rather than sent late.
  update notifications set pushed_at = now() where want_push and pushed_at is null and created_at <= now() - interval '2 hours';
  return jsonb_build_object(
    'vapid_public', (select value from app_secrets where key = 'vapid_public'),
    'vapid_private', (select value from app_secrets where key = 'vapid_private'),
    'subject', coalesce((select value from app_secrets where key = 'vapid_subject'), 'mailto:admin@classi.app'),
    'items', v_items);
end $$;

create or replace function public.drop_push_subscriptions(p_secret text, p_endpoints text[]) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_secret is null or p_secret is distinct from (select value from app_secrets where key = 'dispatch_secret') then
    raise exception 'unauthorized';
  end if;
  delete from push_subscriptions where endpoint = any(p_endpoints);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Wakes the dispatcher when there is something to deliver (pg_net, asynchronous).
create or replace function public.push_kick() returns void
language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text;
begin
  if not exists (select 1 from notifications where want_push and pushed_at is null and created_at > now() - interval '2 hours') then return; end if;
  select value into v_url from app_secrets where key = 'dispatch_url';
  select value into v_secret from app_secrets where key = 'dispatch_secret';
  if v_url is null or v_secret is null then return; end if;
  perform net.http_post(url := v_url, body := jsonb_build_object('secret', v_secret),
                        headers := '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 20000);
end $$;

revoke execute on function public.send_reminders, public.push_kick from anon, authenticated, public;
revoke execute on function public.save_push_subscription, public.remove_push_subscription from anon, public;
grant execute on function public.save_push_subscription, public.remove_push_subscription to authenticated;
grant execute on function public.claim_push, public.drop_push_subscriptions to anon, authenticated;

-- ================= schedule (Supabase: pg_cron + pg_net; skipped where unavailable) =================
do $$
begin
  begin
    create extension if not exists pg_net with schema extensions;
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron/pg_net not available here: %', sqlerrm;
    return;
  end;
  perform cron.unschedule(jobid) from cron.job where jobname in ('classi-reminders', 'classi-push');
  perform cron.schedule('classi-reminders', '*/5 * * * *', 'select public.send_reminders()');
  perform cron.schedule('classi-push', '* * * * *', 'select public.push_kick()');
end $$;
