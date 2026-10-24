-- Classi: moderation (reports, suspend/ban, hide content), header counts, health check.

-- ================= account status =================
alter table public.profiles add column if not exists status text not null default 'active'
  check (status in ('active','suspended','banned'));
alter table public.profiles add column if not exists suspended_until timestamptz;
alter table public.profiles add column if not exists status_reason text;

-- Hidden by the admin (separate from the owner's own "hide offer").
alter table public.teachers   add column if not exists moderation_hidden boolean not null default false;
alter table public.institutes add column if not exists moderation_hidden boolean not null default false;
alter table public.offerings  add column if not exists moderation_hidden boolean not null default false;

-- Users can't change their own status or un-hide what the admin hid.
create or replace function public.protect_profile_roles() returns trigger
language plpgsql as $$
begin
  if current_user in ('anon','authenticated') then
    if 'admin' = any(new.roles) and not 'admin' = any(old.roles) then
      new.roles := array_remove(new.roles, 'admin');
    end if;
    if new.active_role <> all(new.roles) then new.active_role := old.active_role; end if;
    new.status := old.status; new.suspended_until := old.suspended_until; new.status_reason := old.status_reason;
  end if;
  return new;
end $$;

create or replace function public.protect_admin_fields() returns trigger
language plpgsql as $$
begin
  if current_user in ('anon','authenticated') then
    if tg_op = 'INSERT' then
      new.verify := 'pending'; new.rating := 0; new.reviews_count := 0; new.moderation_hidden := false;
    else
      new.verify := old.verify; new.rating := old.rating; new.reviews_count := old.reviews_count;
      new.moderation_hidden := old.moderation_hidden;
    end if;
  end if;
  return new;
end $$;

create or replace function public.protect_offering_moderation() returns trigger
language plpgsql as $$
begin
  if current_user in ('anon','authenticated') then
    if tg_op = 'INSERT' then new.moderation_hidden := false; else new.moderation_hidden := old.moderation_hidden; end if;
  end if;
  return new;
end $$;
drop trigger if exists offerings_protect_moderation on public.offerings;
create trigger offerings_protect_moderation before insert or update on public.offerings
  for each row execute function public.protect_offering_moderation();

-- Is the caller allowed to act (not suspended or banned)?
create or replace function public.is_active_user(p_user uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select status = 'active' or (status = 'suspended' and suspended_until is not null and suspended_until <= now())
                   from profiles where id = p_user), true)
$$;
grant execute on function public.is_active_user to anon, authenticated;

-- Visibility: hidden or banned owners disappear from the public catalogue.
create or replace function public.offering_owner_verified(p_offering uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select t.verify = 'verified' and not t.moderation_hidden and (t.user_id is null or is_active_user(t.user_id))
       from offerings o join teachers t on t.id = o.teacher_id where o.id = p_offering),
    (select i.verify = 'verified' and not i.moderation_hidden and (i.owner_id is null or is_active_user(i.owner_id))
       from offerings o join institutes i on i.id = o.institute_id where o.id = p_offering),
    false)
$$;

drop policy if exists "read offerings" on public.offerings;
create policy "read offerings" on public.offerings for select
  using ((active and not moderation_hidden and offering_owner_verified(id)) or is_offering_owner(id) or is_admin()
         or exists (select 1 from bookings b where b.offering_id = offerings.id and b.booked_by = auth.uid()));

drop policy if exists "read teachers" on public.teachers;
create policy "read teachers" on public.teachers for select
  using ((verify = 'verified' and not moderation_hidden and (user_id is null or is_active_user(user_id))) or user_id = auth.uid());
drop policy if exists "read institutes" on public.institutes;
create policy "read institutes" on public.institutes for select
  using ((verify = 'verified' and not moderation_hidden and (owner_id is null or is_active_user(owner_id))) or owner_id = auth.uid());

-- Suspended or banned accounts can't write.
drop policy if exists "members send messages" on public.messages;
create policy "members send messages" on public.messages for insert
  with check (sender_id = auth.uid() and is_conversation_member(conversation_id) and is_active_user());

drop policy if exists "owner writes offerings" on public.offerings;
create policy "owner writes offerings" on public.offerings for insert with check (
  is_active_user() and (
  (teacher_id is not null and teacher_id = my_teacher_id())
  or (institute_id is not null and exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()))));

create or replace function public.block_inactive_booking() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_active_user(new.booked_by) then raise exception 'حسابك موقوف ولا يمكنه الحجز'; end if;
  return new;
end $$;
drop trigger if exists bookings_block_inactive on public.bookings;
create trigger bookings_block_inactive before insert on public.bookings
  for each row execute function public.block_inactive_booking();

-- ================= reports =================
create table if not exists public.reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  target_type  text not null check (target_type in ('teacher','institute','offering','user')),
  target_id    uuid not null,
  reason       text not null check (reason in ('inappropriate','fake','no_show','safety','overcharge','other')),
  details      text check (length(details) <= 1000),
  status       text not null default 'open' check (status in ('open','resolved','dismissed')),
  admin_note   text,
  resolved_by  uuid references public.profiles(id),
  resolved_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists reports_open on public.reports (status, created_at);
alter table public.reports enable row level security;
create policy "report anything once signed in" on public.reports for insert
  with check (reporter_id = auth.uid() and is_active_user());
create policy "see own reports or admin" on public.reports for select using (reporter_id = auth.uid() or is_admin());
create policy "admin updates reports" on public.reports for update using (is_admin()) with check (is_admin());
grant select, insert, update on public.reports to authenticated;

create or replace function public.on_content_report() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from reports where reporter_id = new.reporter_id and target_id = new.target_id
             and status = 'open' and id <> new.id) then
    raise exception 'سبق أن أبلغت عن هذا، والبلاغ قيد المراجعة';
  end if;
  insert into notifications (user_id, kind, body, link)
  select p.id, 'report', 'بلاغ جديد من مستخدم. افتح لوحة الإدارة للمراجعة.', '/admin'
  from profiles p where 'admin' = any(p.roles);
  return new;
end $$;
drop trigger if exists reports_notify on public.reports;
create trigger reports_notify after insert on public.reports
  for each row execute function public.on_content_report();

-- ================= moderation log + actions =================
create table if not exists public.moderation_actions (
  id          uuid primary key default gen_random_uuid(),
  admin_id    uuid references public.profiles(id),
  target_type text not null,
  target_id   uuid not null,
  action      text not null,
  reason      text,
  created_at  timestamptz not null default now()
);
alter table public.moderation_actions enable row level security;
create policy "admin reads log" on public.moderation_actions for select using (is_admin());
grant select on public.moderation_actions to authenticated;

-- Suspend for N days, ban, or reactivate an account. Also blocks sign-in at the
-- sign-in service, and hides the person's teacher/institute listings.
create or replace function public.admin_set_user_status(p_user uuid, p_status text, p_days int default null, p_reason text default null)
returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_until timestamptz;
begin
  if not is_admin() then raise exception 'هذه العملية للمدير فقط'; end if;
  if p_user = auth.uid() then raise exception 'لا يمكنك إيقاف حسابك أنت'; end if;
  if p_status not in ('active','suspended','banned') then raise exception 'حالة غير معروفة'; end if;
  v_until := case when p_status = 'suspended' then now() + make_interval(days => coalesce(p_days, 7)) end;

  update profiles set status = p_status, suspended_until = v_until,
                      status_reason = case when p_status = 'active' then null else nullif(trim(p_reason), '') end
   where id = p_user;
  if not found then raise exception 'الحساب غير موجود'; end if;

  update auth.users set banned_until = case p_status when 'banned' then 'infinity'::timestamptz
                                                     when 'suspended' then v_until else null end
   where id = p_user;

  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), 'user', p_user, p_status || coalesce(' ' || p_days || 'd', ''), p_reason);

  if p_status = 'active' then
    insert into notifications (user_id, kind, body, link) values (p_user, 'moderation', 'أُعيد تفعيل حسابك في Classi.', '/');
  end if;
end $$;

-- Hide or show a teacher listing, institute, or single offer.
create or replace function public.admin_hide(p_kind text, p_id uuid, p_hidden boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_name text;
begin
  if not is_admin() then raise exception 'هذه العملية للمدير فقط'; end if;
  if p_kind = 'teacher' then
    update teachers set moderation_hidden = p_hidden where id = p_id returning user_id, name into v_owner, v_name;
  elsif p_kind = 'institute' then
    update institutes set moderation_hidden = p_hidden where id = p_id returning owner_id, name into v_owner, v_name;
  elsif p_kind = 'offering' then
    update offerings set moderation_hidden = p_hidden where id = p_id returning offering_owner_user(id), title into v_owner, v_name;
  else
    raise exception 'نوع غير معروف';
  end if;
  if v_name is null then raise exception 'العنصر غير موجود'; end if;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), p_kind, p_id, case when p_hidden then 'hide' else 'show' end, p_reason);
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (v_owner, 'moderation',
      case when p_hidden then format('أخفت الإدارة «%s» عن الطلاب%s. راسل الإدارة للاستفسار.', v_name, coalesce('. السبب: ' || nullif(trim(p_reason), ''), ''))
           else format('أعادت الإدارة إظهار «%s» للطلاب.', v_name) end,
      case when p_kind = 'institute' then '/manage' else '/teach' end);
  end if;
end $$;

-- Close a report, with an optional note.
create or replace function public.admin_close_report(p_report uuid, p_status text, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'هذه العملية للمدير فقط'; end if;
  if p_status not in ('resolved','dismissed') then raise exception 'حالة غير معروفة'; end if;
  update reports set status = p_status, admin_note = nullif(trim(p_note), ''), resolved_by = auth.uid(), resolved_at = now()
   where id = p_report;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), 'report', p_report, p_status, p_note);
end $$;

-- Accounts list for the admin (with email, which only the sign-in service holds).
create or replace function public.admin_users(p_search text default null)
returns table (id uuid, full_name text, email text, town text, roles public.app_role[], status text,
               suspended_until timestamptz, created_at timestamptz, last_sign_in_at timestamptz,
               teacher_id uuid, institute_id uuid, open_reports int)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  return query
  select p.id, p.full_name, u.email::text, p.town, p.roles, p.status, p.suspended_until, p.created_at, u.last_sign_in_at,
         t.id, i.id,
         (select count(*)::int from reports r where r.status = 'open'
            and (r.target_id = p.id or r.target_id = t.id or r.target_id = i.id
                 or r.target_id in (select o.id from offerings o where o.teacher_id = t.id or o.institute_id = i.id)))
  from profiles p
  join auth.users u on u.id = p.id
  left join teachers t on t.user_id = p.id
  left join institutes i on i.owner_id = p.id
  where p_search is null or p_search = ''
     or p.full_name ilike '%' || p_search || '%' or u.email ilike '%' || p_search || '%'
     or t.name ilike '%' || p_search || '%' or i.name ilike '%' || p_search || '%'
  order by p.created_at desc
  limit 100;
end $$;

-- Open reports with a readable name for what was reported.
create or replace function public.admin_reports()
returns table (id uuid, target_type text, target_id uuid, target_name text, owner_id uuid, reason text, details text,
               reporter_name text, created_at timestamptz, same_target_open int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  return query
  select r.id, r.target_type, r.target_id,
         coalesce(t.name, i.name, o.title, pu.full_name, '—'),
         coalesce(t.user_id, i.owner_id, offering_owner_user(o.id), pu.id),
         r.reason, r.details, coalesce(rp.full_name, ''), r.created_at,
         (select count(*)::int from reports x where x.target_id = r.target_id and x.status = 'open')
  from reports r
  left join teachers t on r.target_type = 'teacher' and t.id = r.target_id
  left join institutes i on r.target_type = 'institute' and i.id = r.target_id
  left join offerings o on r.target_type = 'offering' and o.id = r.target_id
  left join profiles pu on r.target_type = 'user' and pu.id = r.target_id
  left join profiles rp on rp.id = r.reporter_id
  where r.status = 'open'
  order by r.created_at;
end $$;

revoke execute on function public.admin_set_user_status, public.admin_hide, public.admin_close_report, public.admin_users, public.admin_reports from anon, public;
grant execute on function public.admin_set_user_status, public.admin_hide, public.admin_close_report, public.admin_users, public.admin_reports to authenticated;

-- ================= header counts in one call =================
create or replace function public.my_header_counts()
returns table (notifications int, messages int)
language sql stable security definer set search_path = public as $$
  select
    (select count(*)::int from notifications n where n.user_id = auth.uid() and n.read_at is null and n.kind <> 'message'),
    (select count(*)::int from messages m join conversations c on c.id = m.conversation_id
      left join teachers t on t.id = c.teacher_id left join institutes i on i.id = c.institute_id
      where m.read_at is null and m.sender_id <> auth.uid()
        and (c.user_id = auth.uid() or coalesce(t.user_id, i.owner_id) = auth.uid()))
$$;
revoke execute on function public.my_header_counts from anon, public;
grant execute on function public.my_header_counts to authenticated;

-- ================= health check =================
-- Readable by anyone: answers only whether the database responds, plus counts.
create or replace function public.health_ping()
returns table (ok boolean, offerings int, accounts int, checked_at timestamptz)
language sql stable security definer set search_path = public as $$
  select true, (select count(*)::int from offerings), (select count(*)::int from profiles), now()
$$;
grant execute on function public.health_ping to anon, authenticated;
