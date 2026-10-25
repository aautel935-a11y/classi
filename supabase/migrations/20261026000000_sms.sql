-- Classi: SMS through 019 for the messages that matter most.
-- Sent only to people who added a mobile number and kept "SMS reminders" on:
--  · the day-before lesson reminder
--  · a lesson moved or cancelled
-- Everything else stays on the site, the phone notifications and email (free).

create table if not exists public.sms_log (
  id              uuid primary key default gen_random_uuid(),
  notification_id uuid references public.notifications(id) on delete set null,
  phone           text not null,
  ok              boolean not null,
  detail          text,
  created_at      timestamptz not null default now()
);
alter table public.sms_log enable row level security;
create policy "admins read sms log" on public.sms_log for select using (is_admin());
grant select on public.sms_log to authenticated;

create or replace function public.sms_kinds() returns text[] language sql immutable as $$
  select array['reminder','schedule_changed','booking_cancelled']
$$;

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
           'phone', case when pk.kind = any(sms_kinds()) and pr.sms_ok and is_active_user(pr.id) then pr.phone end,
           'name', pr.full_name,
           'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth)))
                               from push_subscriptions s where s.user_id = pk.user_id), '[]'::jsonb))), '[]'::jsonb)
    into v_items
    from picked pk join profiles pr on pr.id = pk.user_id left join auth.users u on u.id = pk.user_id;
  update notifications set pushed_at = now() where want_push and pushed_at is null and created_at <= now() - interval '2 hours';
  return jsonb_build_object(
    'vapid_public', (select value from app_secrets where key = 'vapid_public'),
    'vapid_private', (select value from app_secrets where key = 'vapid_private'),
    'subject', coalesce((select value from app_secrets where key = 'vapid_subject'), 'mailto:admin@classi.app'),
    'items', v_items);
end $$;

-- The dispatcher records each SMS it tried, for the admin's monthly count.
create or replace function public.log_sms(p_secret text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_secret is null or p_secret is distinct from (select value from app_secrets where key = 'dispatch_secret') then
    raise exception 'unauthorized';
  end if;
  insert into sms_log (notification_id, phone, ok, detail)
  select nullif(r->>'id', '')::uuid, r->>'phone', coalesce((r->>'ok')::boolean, false), left(r->>'detail', 300)
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.admin_sms_stats()
returns table (sent_month int, failed_month int, sent_total int)
language sql stable security definer set search_path = public as $$
  select count(*) filter (where ok and created_at >= date_trunc('month', now()))::int,
         count(*) filter (where not ok and created_at >= date_trunc('month', now()))::int,
         count(*) filter (where ok)::int
    from sms_log where is_admin()
$$;

revoke execute on function public.log_sms, public.admin_sms_stats from anon, public;
grant execute on function public.log_sms to anon, authenticated;
grant execute on function public.admin_sms_stats to authenticated;
