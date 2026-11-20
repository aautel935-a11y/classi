-- Classi trades, foundation (20/11/2026): professions, provider registration, service requests and quotes.
-- ADDITIVE ONLY: no education table, function or policy is changed. A provider is an existing business owner
-- (a teachers row = a person, an institutes row = a company), exactly as the v3 ledger owns charges; nothing here
-- depends on v3. Nothing a provider registers is visible before an admin approves it (standing rule).
-- Not in the production files (scripts/production stops before v3); local and CI only until the owner approves.

------------------------------------------------------------------------------------------------------------
-- 1. Tables (RLS on, no policies, no grants: everything goes through the functions below)
------------------------------------------------------------------------------------------------------------
create table if not exists public.professions (
  id       smallint generated always as identity primary key,
  slug     text not null unique check (slug ~ '^[a-z][a-z0-9_]{1,30}$'),
  name_ar  text not null check (length(trim(name_ar)) between 2 and 40),
  active   boolean not null default true,
  sort     smallint not null default 100
);
insert into public.professions (slug, name_ar, sort) values
  ('electrician', 'كهربائي', 10), ('plumber', 'سبّاك', 20), ('carpenter', 'نجّار', 30), ('blacksmith', 'حدّاد', 40),
  ('locksmith', 'مفاتيح وأقفال', 50), ('gardener', 'بستاني', 60), ('painter', 'دهّان', 70), ('ac_tech', 'فني تكييف', 80)
on conflict (slug) do nothing;

create table if not exists public.provider_professions (
  id            uuid primary key default gen_random_uuid(),
  teacher_id    uuid references public.teachers(id) on delete cascade,
  institute_id  uuid references public.institutes(id) on delete cascade,
  profession_id smallint not null references public.professions(id),
  towns         text[] not null default '{}' check (cardinality(towns) <= 20),   -- normalized; empty = every town
  created_at    timestamptz not null default now(),
  approved_at   timestamptz,
  approved_by   uuid,
  constraint provider_professions_one_owner check ((teacher_id is null) <> (institute_id is null))
);
create unique index if not exists provider_professions_once on public.provider_professions
  (coalesce(teacher_id, institute_id), profession_id);

create table if not exists public.service_requests (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references public.profiles(id) on delete cascade,
  profession_id smallint not null references public.professions(id),
  town          text not null check (length(town) between 2 and 60),          -- normalized (trades_town)
  description   text not null check (length(trim(description)) between 10 and 2000),
  preferred     text check (preferred is null or length(preferred) <= 120),   -- "this week, mornings"
  status        text not null default 'open' check (status in ('open','quoted','accepted','cancelled','expired')),
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '7 days',
  accepted_quote uuid
);
create index if not exists service_requests_customer on public.service_requests (customer_id, created_at desc);
create index if not exists service_requests_open on public.service_requests (profession_id, town) where status in ('open','quoted');

create table if not exists public.quotes (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references public.service_requests(id) on delete cascade,
  teacher_id   uuid references public.teachers(id) on delete cascade,
  institute_id uuid references public.institutes(id) on delete cascade,
  price_min    numeric(12,2) not null check (price_min > 0 and price_min <= 1000000),
  price_max    numeric(12,2) not null check (price_max >= price_min and price_max <= 1000000),
  includes     text not null check (length(trim(includes)) between 3 and 1000),
  valid_until  date not null,
  proposed_at  timestamptz,
  status       text not null default 'sent' check (status in ('sent','withdrawn','accepted','declined','expired')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint quotes_one_owner check ((teacher_id is null) <> (institute_id is null))
);
create unique index if not exists quotes_one_per_provider on public.quotes (request_id, coalesce(teacher_id, institute_id));
alter table public.service_requests add constraint service_requests_accepted_quote
  foreign key (accepted_quote) references public.quotes(id) on delete set null deferrable initially deferred;

alter table public.professions enable row level security;
alter table public.provider_professions enable row level security;
alter table public.service_requests enable row level security;
alter table public.quotes enable row level security;
revoke all on public.professions, public.provider_professions, public.service_requests, public.quotes from anon, authenticated;

------------------------------------------------------------------------------------------------------------
-- 2. Helpers (not callable by users)
------------------------------------------------------------------------------------------------------------
create or replace function public.trades_town(p text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g'))
$$;

create or replace function public.trades_is_owner(p_teacher uuid, p_institute uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and ((p_teacher is null) <> (p_institute is null)) and (
         (p_teacher is not null and exists (select 1 from teachers where id = p_teacher and user_id = auth.uid()))
      or (p_institute is not null and exists (select 1 from institutes where id = p_institute and owner_id = auth.uid())))
$$;

-- the provider may see / quote this request: an APPROVED registration for its profession that covers its town
create or replace function public.trades_matches(p_teacher uuid, p_institute uuid, p_request uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from service_requests r join provider_professions pp on pp.profession_id = r.profession_id
     where r.id = p_request and pp.approved_at is not null
       and pp.teacher_id is not distinct from p_teacher and pp.institute_id is not distinct from p_institute
       and (cardinality(pp.towns) = 0 or r.town = any (pp.towns)))
$$;

create or replace function public.trades_owner_user(p_teacher uuid, p_institute uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select user_id from teachers where id = p_teacher), (select owner_id from institutes where id = p_institute))
$$;

revoke all on function public.trades_town(text), public.trades_is_owner(uuid, uuid), public.trades_matches(uuid, uuid, uuid),
  public.trades_owner_user(uuid, uuid) from public, anon, authenticated;

------------------------------------------------------------------------------------------------------------
-- 3. Professions and provider registration (admin approval before anything is visible)
------------------------------------------------------------------------------------------------------------
create or replace function public.list_professions()
returns table (id smallint, slug text, name_ar text)
language sql stable security definer set search_path = public, pg_temp as $$
  select id, slug, name_ar from professions where active order by sort, name_ar
$$;

create or replace function public.register_profession(p_teacher uuid, p_institute uuid, p_profession smallint, p_towns text[] default '{}')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_towns text[];
begin
  if not trades_is_owner(p_teacher, p_institute) or not is_active_user() then raise exception 'ليست لديك صلاحية على هذا النشاط' using errcode = '42501'; end if;
  if not exists (select 1 from professions where id = p_profession and active) then raise exception 'مهنة غير معروفة'; end if;
  select coalesce(array_agg(distinct t) filter (where length(t) between 2 and 60), '{}') into v_towns
    from unnest(coalesce(p_towns, '{}')) x, lateral (select trades_town(x) t) n;
  if cardinality(v_towns) > 20 then raise exception 'حتى 20 بلدة'; end if;
  insert into provider_professions (teacher_id, institute_id, profession_id, towns)
  values (p_teacher, p_institute, p_profession, v_towns)
  on conflict ((coalesce(teacher_id, institute_id)), profession_id)
  do update set towns = excluded.towns, approved_at = null, approved_by = null   -- a change is reviewed again
  returning id into v_id;
  perform notify_admins('طلب تسجيل مهنة جديد بانتظار المراجعة', '/admin');
  return v_id;
end $$;

create or replace function public.my_professions(p_teacher uuid, p_institute uuid)
returns table (id uuid, profession text, towns text[], approved boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not trades_is_owner(p_teacher, p_institute) then return; end if;
  return query select pp.id, p.name_ar, pp.towns, pp.approved_at is not null
    from provider_professions pp join professions p on p.id = pp.profession_id
   where pp.teacher_id is not distinct from p_teacher and pp.institute_id is not distinct from p_institute
   order by p.sort;
end $$;

create or replace function public.admin_profession_queue()
returns table (id uuid, provider text, profession text, towns text[], created_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not is_admin() then raise exception 'للمدير فقط' using errcode = '42501'; end if;
  return query select pp.id, coalesce(t.name, i.name), p.name_ar, pp.towns, pp.created_at
    from provider_professions pp join professions p on p.id = pp.profession_id
    left join teachers t on t.id = pp.teacher_id left join institutes i on i.id = pp.institute_id
   where pp.approved_at is null order by pp.created_at;
end $$;

create or replace function public.admin_review_profession(p_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r provider_professions%rowtype;
begin
  if not is_admin() then raise exception 'للمدير فقط' using errcode = '42501'; end if;
  select * into r from provider_professions where id = p_id for update;
  if not found then raise exception 'التسجيل غير موجود'; end if;
  if p_approve then update provider_professions set approved_at = now(), approved_by = auth.uid() where id = p_id;
  else delete from provider_professions where id = p_id; end if;
  insert into notifications (user_id, kind, body, link)
  select u, 'profession_review', case when p_approve then 'تمت الموافقة على تسجيل مهنتك.' else 'لم تتم الموافقة على تسجيل مهنتك.' end, '/'
    from (select trades_owner_user(r.teacher_id, r.institute_id) u) x where u is not null;
end $$;

------------------------------------------------------------------------------------------------------------
-- 4. Customers: requests and the quotes they receive
------------------------------------------------------------------------------------------------------------
create or replace function public.create_service_request(p_profession smallint, p_town text, p_description text, p_preferred text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_town text := trades_town(p_town);
begin
  if auth.uid() is null or not is_active_user() then raise exception 'سجّل الدخول أولاً' using errcode = '42501'; end if;
  if not exists (select 1 from professions where id = p_profession and active) then raise exception 'اختر المهنة'; end if;
  if length(v_town) < 2 then raise exception 'اكتب اسم البلدة'; end if;
  if length(trim(coalesce(p_description, ''))) < 10 then raise exception 'صف العمل المطلوب بعشرة أحرف على الأقل'; end if;
  perform pg_advisory_xact_lock(hashtext('service_requests:' || auth.uid()::text));
  if (select count(*) from service_requests where customer_id = auth.uid() and status in ('open','quoted') and expires_at > now()) >= 5 then
    raise exception 'لديك 5 طلبات مفتوحة. أغلق أحدها أولاً.';
  end if;
  insert into service_requests (customer_id, profession_id, town, description, preferred)
  values (auth.uid(), p_profession, v_town, trim(p_description), nullif(trim(coalesce(p_preferred, '')), ''))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.cancel_service_request(p_request uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update service_requests set status = 'cancelled'
   where id = p_request and customer_id = auth.uid() and status in ('open','quoted');
  if not found then raise exception 'لا يمكن إلغاء هذا الطلب'; end if;
  update quotes set status = 'declined', updated_at = now() where request_id = p_request and status = 'sent';
end $$;

create or replace function public.my_service_requests()
returns table (id uuid, profession text, town text, description text, preferred text, status text,
               created_at timestamptz, expires_at timestamptz, quotes int)
language sql stable security definer set search_path = public, pg_temp as $$
  select r.id, p.name_ar, r.town, r.description, r.preferred,
         case when r.status in ('open','quoted') and r.expires_at <= now() then 'expired' else r.status end,
         r.created_at, r.expires_at,
         (select count(*)::int from quotes q where q.request_id = r.id and q.status in ('sent','accepted'))
    from service_requests r join professions p on p.id = r.profession_id
   where r.customer_id = auth.uid()
   order by r.created_at desc
$$;

create or replace function public.request_quotes(p_request uuid)
returns table (id uuid, teacher_id uuid, institute_id uuid, provider text, price_min numeric, price_max numeric,
               includes text, valid_until date, proposed_at timestamptz, status text)
language sql stable security definer set search_path = public, pg_temp as $$
  select q.id, q.teacher_id, q.institute_id, coalesce(t.name, i.name), q.price_min, q.price_max, q.includes, q.valid_until,
         q.proposed_at, case when q.status = 'sent' and q.valid_until < current_date then 'expired' else q.status end
    from quotes q join service_requests r on r.id = q.request_id
    left join teachers t on t.id = q.teacher_id left join institutes i on i.id = q.institute_id
   where q.request_id = p_request and r.customer_id = auth.uid() and q.status in ('sent','accepted','declined')
   order by q.price_min, q.created_at
$$;

create or replace function public.accept_quote(p_quote uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare q quotes%rowtype; r service_requests%rowtype;
begin
  select * into q from quotes where id = p_quote for update;
  if not found then raise exception 'العرض غير موجود'; end if;
  select * into r from service_requests where id = q.request_id for update;
  if r.customer_id is distinct from auth.uid() then raise exception 'ليس طلبك' using errcode = '42501'; end if;
  if r.status not in ('open','quoted') or r.expires_at <= now() then raise exception 'الطلب لم يعد مفتوحاً'; end if;
  if q.status <> 'sent' or q.valid_until < current_date then raise exception 'العرض لم يعد صالحاً'; end if;
  update quotes set status = 'accepted', updated_at = now() where id = q.id;
  update quotes set status = 'declined', updated_at = now() where request_id = r.id and id <> q.id and status = 'sent';
  update service_requests set status = 'accepted', accepted_quote = q.id where id = r.id;
  insert into notifications (user_id, kind, body, link)
  select u, 'quote_accepted', 'قُبل عرض السعر الذي أرسلته. تواصل مع الزبون من الرسائل.', '/messages'
    from (select trades_owner_user(q.teacher_id, q.institute_id) u) x where u is not null;
end $$;

------------------------------------------------------------------------------------------------------------
-- 5. Providers: matching requests (no customer identity before acceptance) and quotes
------------------------------------------------------------------------------------------------------------
create or replace function public.open_requests_for(p_teacher uuid, p_institute uuid)
returns table (id uuid, profession text, town text, description text, preferred text, created_at timestamptz,
               expires_at timestamptz, my_quote uuid, my_quote_status text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not trades_is_owner(p_teacher, p_institute) then return; end if;
  return query
  select r.id, p.name_ar, r.town, r.description, r.preferred, r.created_at, r.expires_at, q.id, q.status
    from service_requests r join professions p on p.id = r.profession_id
    left join quotes q on q.request_id = r.id and q.teacher_id is not distinct from p_teacher and q.institute_id is not distinct from p_institute
   where r.status in ('open','quoted') and r.expires_at > now()
     and r.customer_id <> auth.uid()
     and trades_matches(p_teacher, p_institute, r.id)
   order by r.created_at desc
   limit 100;
end $$;

create or replace function public.send_quote(p_request uuid, p_teacher uuid, p_institute uuid, p_min numeric, p_max numeric,
                                             p_includes text, p_valid_until date, p_proposed_at timestamptz default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare r service_requests%rowtype; v_id uuid;
begin
  if not trades_is_owner(p_teacher, p_institute) or not is_active_user() then raise exception 'ليست لديك صلاحية على هذا النشاط' using errcode = '42501'; end if;
  select * into r from service_requests where id = p_request for update;
  if not found or not trades_matches(p_teacher, p_institute, p_request) then raise exception 'هذا الطلب ليس ضمن مهنتك أو بلدتك' using errcode = '42501'; end if;
  if r.customer_id = auth.uid() then raise exception 'لا يمكن تقديم عرض لطلبك أنت'; end if;
  if r.status not in ('open','quoted') or r.expires_at <= now() then raise exception 'الطلب لم يعد مفتوحاً'; end if;
  if p_min is null or p_max is null or p_min <= 0 or p_max < p_min or p_max > 1000000 then raise exception 'السعر غير صالح'; end if;
  if p_valid_until is null or p_valid_until < current_date or p_valid_until > current_date + 60 then raise exception 'اختر تاريخ صلاحية خلال 60 يوماً'; end if;
  if p_proposed_at is not null and p_proposed_at < now() then raise exception 'الموعد المقترح في الماضي'; end if;
  insert into quotes (request_id, teacher_id, institute_id, price_min, price_max, includes, valid_until, proposed_at)
  values (p_request, p_teacher, p_institute, round(p_min, 2), round(p_max, 2), trim(coalesce(p_includes, '')), p_valid_until, p_proposed_at)
  on conflict (request_id, (coalesce(teacher_id, institute_id))) do update
     set price_min = excluded.price_min, price_max = excluded.price_max, includes = excluded.includes,
         valid_until = excluded.valid_until, proposed_at = excluded.proposed_at, status = 'sent', updated_at = now()
   where quotes.status in ('sent','withdrawn')
  returning id into v_id;
  if v_id is null then raise exception 'لا يمكن تعديل هذا العرض بعد الآن'; end if;
  update service_requests set status = 'quoted' where id = p_request and status = 'open';
  insert into notifications (user_id, kind, body, link) values (r.customer_id, 'quote_new', 'وصلك عرض سعر جديد على طلبك.', '/');
  return v_id;
end $$;

create or replace function public.withdraw_quote(p_quote uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare q quotes%rowtype;
begin
  select * into q from quotes where id = p_quote for update;
  if not found or not trades_is_owner(q.teacher_id, q.institute_id) then raise exception 'ليست لديك صلاحية على هذا العرض' using errcode = '42501'; end if;
  if q.status <> 'sent' then raise exception 'لا يمكن سحب هذا العرض'; end if;
  update quotes set status = 'withdrawn', updated_at = now() where id = q.id;
end $$;

------------------------------------------------------------------------------------------------------------
-- 6. Housekeeping (scheduled job candidate; not scheduled yet)
------------------------------------------------------------------------------------------------------------
create or replace function public.expire_service_requests() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  update service_requests set status = 'expired' where status in ('open','quoted') and expires_at <= now();
  get diagnostics n = row_count;
  update quotes set status = 'expired', updated_at = now() where status = 'sent' and valid_until < current_date;
  return n;
end $$;

------------------------------------------------------------------------------------------------------------
-- 7. Grants
------------------------------------------------------------------------------------------------------------
revoke all on function public.list_professions(), public.register_profession(uuid, uuid, smallint, text[]),
  public.my_professions(uuid, uuid), public.admin_profession_queue(), public.admin_review_profession(uuid, boolean),
  public.create_service_request(smallint, text, text, text), public.cancel_service_request(uuid), public.my_service_requests(),
  public.request_quotes(uuid), public.accept_quote(uuid), public.open_requests_for(uuid, uuid),
  public.send_quote(uuid, uuid, uuid, numeric, numeric, text, date, timestamptz), public.withdraw_quote(uuid),
  public.expire_service_requests() from public, anon, authenticated;
grant execute on function public.list_professions() to anon, authenticated;
grant execute on function public.register_profession(uuid, uuid, smallint, text[]), public.my_professions(uuid, uuid),
  public.admin_profession_queue(), public.admin_review_profession(uuid, boolean),
  public.create_service_request(smallint, text, text, text), public.cancel_service_request(uuid), public.my_service_requests(),
  public.request_quotes(uuid), public.accept_quote(uuid), public.open_requests_for(uuid, uuid),
  public.send_quote(uuid, uuid, uuid, numeric, numeric, text, date, timestamptz), public.withdraw_quote(uuid) to authenticated;
