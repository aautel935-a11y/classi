-- Classi: production hardening (audit 31/10/2026, findings SEC-01 … SEC-33 in CLASSI_SECURITY_AUDIT.md).
-- Safe to run on a live database: new columns have defaults, new CHECK constraints are NOT VALID (old rows are
-- not re-checked), and no existing row is deleted. Rollback notes: docs/hardening/ROLLBACK.md.

------------------------------------------------------------------------------------------------------------
-- 0. Small helpers
------------------------------------------------------------------------------------------------------------
create or replace function public.notifications_mark_push() returns trigger
language plpgsql as $$
begin
  new.want_push := new.kind in ('reminder','reminder_today','reminder_soon','booking_answer','booking_request','booking_new','booking_cancelled',
                                'schedule_changed','waitlist_open','waitlist_answer','waitlist_join','verified','message',
                                'lesson_report','report_due','payment_reported','payment_answer','review_needed','review_answer',
                                'subscription','review_new','review_prompt','admin_note','review',
                                -- new in this migration (push and in-app only, never SMS)
                                'staff_invite','staff_answer','staff_removed','booking_withdrawn','link_request','link_answer');
  return new;
end $$;

------------------------------------------------------------------------------------------------------------
-- 1. SEC-13: a suspended or banned account cannot change anything (not only in the web layout).
------------------------------------------------------------------------------------------------------------
create or replace function public.block_inactive_writer() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and coalesce(current_setting('classi.bypass_active', true), '') <> 'on'
     and not is_active_user(auth.uid()) and not is_admin() then
    raise exception 'حسابك موقوف حالياً ولا يمكنه إجراء تغييرات';
  end if;
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['offerings','sessions','availability','teacher_blocks','institute_teachers','lesson_reports',
                           'offering_links','attendance','rooms','pay_numbers','reviews','conversations','children'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_active_writer', t);
    execute format('create trigger %I before insert or update or delete on public.%I for each row execute function block_inactive_writer()',
                   t || '_active_writer', t);
  end loop;
  -- bookings: inserts are already guarded (bookings_block_inactive); guard updates and deletes too.
  drop trigger if exists bookings_active_writer on public.bookings;
  create trigger bookings_active_writer before update or delete on public.bookings for each row execute function block_inactive_writer();
  drop trigger if exists teachers_active_writer on public.teachers;
  create trigger teachers_active_writer before update on public.teachers for each row execute function block_inactive_writer();
  drop trigger if exists institutes_active_writer on public.institutes;
  create trigger institutes_active_writer before update on public.institutes for each row execute function block_inactive_writer();
end $$;

------------------------------------------------------------------------------------------------------------
-- 2. SEC-02 / SEC-04: institute staff needs the teacher's consent; only accepted staff can be a course teacher.
------------------------------------------------------------------------------------------------------------
alter table public.institute_teachers add column if not exists status text not null default 'accepted';
alter table public.institute_teachers add column if not exists invited_at timestamptz;   -- null for staff from before invitations
alter table public.institute_teachers alter column invited_at set default now();
alter table public.institute_teachers alter column status set default 'invited';
do $$ begin
  alter table public.institute_teachers add constraint institute_teachers_status_chk check (status in ('invited','accepted'));
exception when duplicate_object then null; end $$;
-- Existing rows keep 'accepted' (the column was added with that default), so nothing changes for current staff.

drop policy if exists "institute owner staff" on public.institute_teachers;
drop policy if exists "read inst teachers" on public.institute_teachers;
drop policy if exists "owner invites staff" on public.institute_teachers;
drop policy if exists "owner removes staff" on public.institute_teachers;
create policy "read inst teachers" on public.institute_teachers for select
  using (status = 'accepted' or teacher_id = my_teacher_id()
         or exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()));
create policy "owner invites staff" on public.institute_teachers for insert
  with check (status = 'invited'
              and exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid() and i.verify = 'verified'));
create policy "owner removes staff" on public.institute_teachers for delete
  using (exists (select 1 from institutes i where i.id = institute_id and i.owner_id = auth.uid()));
-- No UPDATE policy: only the teacher accepts, through accept_staff_invite().
revoke update on public.institute_teachers from anon, authenticated;

create or replace function public.institute_teachers_invited() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_inst text; v_n int; v_cap int := coalesce(nullif(setting('staff_invites_per_day'), '')::int, 10);
begin
  if new.status <> 'invited' then return new; end if;
  select count(*) into v_n from institute_teachers where institute_id = new.institute_id and invited_at > now() - interval '1 day';
  if v_n > v_cap then raise exception 'وصلت لحد الدعوات اليومي (%). حاول غداً.', v_cap; end if;
  select name into v_inst from institutes where id = new.institute_id;
  insert into notifications (user_id, kind, body, link)
  values ((select user_id from teachers where id = new.teacher_id), 'staff_invite',
          format('دعاك %s للانضمام إلى طاقمه. اقبل الدعوة أو ارفضها من لوحتك.', v_inst), '/teach#invites');
  return new;
end $$;
drop trigger if exists institute_teachers_invited on public.institute_teachers;
create trigger institute_teachers_invited after insert on public.institute_teachers
  for each row execute function institute_teachers_invited();

create or replace function public.my_staff_invites()
returns table (institute_id uuid, institute_name text, town text, invited_at timestamptz)
language sql stable security definer set search_path = public as $$
  select i.id, i.name, i.town, it.invited_at from institute_teachers it join institutes i on i.id = it.institute_id
   where it.teacher_id = my_teacher_id() and it.status = 'invited' order by it.invited_at desc
$$;

create or replace function public.answer_staff_invite(p_institute uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_teacher uuid := my_teacher_id(); v_owner uuid; v_name text;
begin
  if v_teacher is null then raise exception 'هذه الصفحة للمعلمين'; end if;
  if not is_active_user() then raise exception 'حسابك موقوف حالياً ولا يمكنه إجراء تغييرات'; end if;
  if not exists (select 1 from institute_teachers where institute_id = p_institute and teacher_id = v_teacher and status = 'invited') then
    raise exception 'لا توجد دعوة من هذا المعهد';
  end if;
  if p_accept then
    update institute_teachers set status = 'accepted' where institute_id = p_institute and teacher_id = v_teacher;
  else
    delete from institute_teachers where institute_id = p_institute and teacher_id = v_teacher;
  end if;
  select owner_id into v_owner from institutes where id = p_institute;
  select name into v_name from teachers where id = v_teacher;
  insert into notifications (user_id, kind, body, link) values (v_owner, 'staff_answer',
    case when p_accept then format('قَبِل %s الانضمام إلى طاقمك.', v_name) else format('اعتذر %s عن دعوة الانضمام إلى الطاقم.', v_name) end,
    '/manage');
end $$;

create or replace function public.institute_remove_staff(p_teacher uuid)
returns int language plpgsql security definer set search_path = public as $$
declare v_inst uuid; v_n int; v_user uuid; v_inst_name text; v_status text;
begin
  select id, name into v_inst, v_inst_name from institutes where owner_id = auth.uid() limit 1;
  if v_inst is null then raise exception 'هذه الصفحة لأصحاب المعاهد'; end if;
  select status into v_status from institute_teachers where institute_id = v_inst and teacher_id = p_teacher;
  if v_status is null then raise exception 'المعلم ليس ضمن طاقم المعهد'; end if;
  update offerings set course_teacher_id = null where institute_id = v_inst and course_teacher_id = p_teacher;
  get diagnostics v_n = row_count;
  delete from institute_teachers where institute_id = v_inst and teacher_id = p_teacher;
  -- Only someone who really joined is told, and never by SMS (kind is not in sms_kinds()).
  if v_status = 'accepted' then
    select user_id into v_user from teachers where id = p_teacher;
    insert into notifications (user_id, kind, body, link)
    values (v_user, 'staff_removed', format('لم تعد ضمن طاقم %s.', v_inst_name), '/teach');
  end if;
  return v_n;
end $$;

-- The course teacher must be accepted staff of the course's institute (checked in the database, whatever the client sends).
create or replace function public.offerings_course_teacher_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.course_teacher_id is null or auth.uid() is null then return new; end if;
  if tg_op = 'UPDATE' and new.course_teacher_id is not distinct from old.course_teacher_id then return new; end if;
  if is_admin() then return new; end if;
  if new.institute_id is null or not exists (
       select 1 from institute_teachers where institute_id = new.institute_id and teacher_id = new.course_teacher_id and status = 'accepted') then
    raise exception 'اختر معلماً قَبِل دعوة الانضمام إلى طاقم المعهد';
  end if;
  return new;
end $$;
drop trigger if exists offerings_course_teacher_guard on public.offerings;
create trigger offerings_course_teacher_guard before insert or update of course_teacher_id on public.offerings
  for each row execute function offerings_course_teacher_guard();

-- SEC-04 / F19: lesson lengths are bounded (a 600-minute or negative meeting could block or break a calendar).
do $$ begin
  alter table public.sessions add constraint sessions_minutes_chk check (minutes between 10 and 480) not valid;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.offerings add constraint offerings_minutes_chk check (minutes between 0 and 480) not valid;
exception when duplicate_object then null; end $$;

-- SEC-33: a session can only use a room of its own institute.
create or replace function public.sessions_room_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.room_id is not null and not exists (
       select 1 from rooms r join offerings o on o.institute_id = r.institute_id where r.id = new.room_id and o.id = new.offering_id) then
    raise exception 'هذه القاعة لا تتبع معهدك';
  end if;
  return new;
end $$;
drop trigger if exists sessions_room_guard on public.sessions;
create trigger sessions_room_guard before insert or update of room_id on public.sessions
  for each row execute function sessions_room_guard();

------------------------------------------------------------------------------------------------------------
-- 3. SEC-03 / SEC-10: no phone-number lookups. Walk-ins are linked only when the phone's owner accepts.
------------------------------------------------------------------------------------------------------------
alter table public.bookings add column if not exists link_requested_at timestamptz;

create or replace function public.institute_enroll(p_offering uuid, p_name text, p_phone text default null, p_pay text default 'cash', p_paid boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_phone text := clean_phone(p_phone); v_id uuid; v_name text := nullif(trim(p_name), '');
begin
  select * into o from offerings where id = p_offering;
  if not found or not is_offering_owner(o.id) then raise exception 'لا تملك صلاحية على هذه الدورة'; end if;
  if o.type <> 'course' then raise exception 'التسجيل اليدوي متاح للدورات'; end if;
  if v_name is null then raise exception 'اكتب اسم الطالب'; end if;
  if nullif(trim(coalesce(p_phone, '')), '') is not null and v_phone is null then raise exception 'رقم الهاتف غير صحيح'; end if;
  if p_pay not in ('cash','bit','installments') then raise exception 'طريقة دفع غير معروفة'; end if;
  if o.seats is not null and seats_taken(o.id) >= o.seats then
    raise exception 'الدورة ممتلئة (% من % مقاعد). زِد عدد المقاعد أولاً.', seats_taken(o.id), o.seats;
  end if;
  -- Never linked here: whether this phone has an account stays private. The owner of the number links it
  -- themselves after an invitation (institute_link_booking -> accept_booking_link).
  insert into bookings (offering_id, booked_by, minutes, status, pay_method, mode, price, offline_name, offline_phone)
  values (o.id, null, o.minutes, 'confirmed', p_pay, o.places[1], o.price, v_name, v_phone)
  returning id into v_id;
  if p_paid then
    update bookings set installments_paid = case when installments_total > 1 then 1 else installments_total end,
           pay_status = case when installments_total > 1 then 'unpaid' else 'paid' end,
           paid_at = case when installments_total > 1 then null else now() end
     where id = v_id;
  end if;
  return v_id;
end $$;

-- The institute asks; if (and only if) the number has an account, its owner gets an invitation.
-- The answer to the institute is the same either way.
create or replace function public.institute_link_booking(p_booking uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_user uuid; v_title text; v_inst text;
begin
  select * into b from bookings where id = p_booking;
  if not found or not is_offering_owner(b.offering_id) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  if b.booked_by is not null then raise exception 'الحجز مربوط بحساب سابقاً'; end if;
  if b.offline_phone is null then raise exception 'لا يوجد رقم هاتف لهذا الطالب'; end if;
  if b.link_requested_at > now() - interval '1 day' then raise exception 'أُرسلت دعوة اليوم. انتظر رد ولي الأمر.'; end if;
  update bookings set link_requested_at = now() where id = b.id;
  select id into v_user from profiles where phone = b.offline_phone limit 1;
  if v_user is not null then
    select o.title, coalesce(i.name, t.name) into v_title, v_inst from offerings o
      left join institutes i on i.id = o.institute_id left join teachers t on t.id = o.teacher_id where o.id = b.offering_id;
    insert into notifications (user_id, kind, body, link) values (v_user, 'link_request',
      format('%s سجّل الطالب %s في %s برقم هاتفك. اربط التسجيل بحسابك لترى المواعيد والتقارير والدفعات.', v_inst, b.offline_name, v_title),
      '/schedule#links');
  end if;
end $$;

-- Walk-in enrolments carrying the caller's own verified phone number.
create or replace function public.my_link_requests()
returns table (booking_id uuid, offering_title text, owner_name text, student_name text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select b.id, o.title, coalesce(i.name, t.name), b.offline_name, b.created_at
    from bookings b join offerings o on o.id = b.offering_id
    left join institutes i on i.id = o.institute_id left join teachers t on t.id = o.teacher_id
   where b.booked_by is null and b.status in ('pending','confirmed')
     and b.offline_phone is not null and b.offline_phone = (select phone from profiles where id = auth.uid())
   order by b.created_at desc
$$;

create or replace function public.accept_booking_link(p_booking uuid, p_accept boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_phone text; v_owner uuid; v_me text;
begin
  select phone, full_name into v_phone, v_me from profiles where id = auth.uid();
  select * into b from bookings where id = p_booking for update;
  if not found or b.booked_by is not null or b.offline_phone is null or b.offline_phone is distinct from v_phone then
    raise exception 'هذا التسجيل غير مرتبط برقم هاتفك';
  end if;
  v_owner := offering_owner_user(b.offering_id);
  if p_accept then
    update bookings set booked_by = auth.uid() where id = b.id;
    update lesson_reports set student_user = auth.uid() where booking_id = b.id and student_user is null;
  else
    -- Not my child: the number stays on the walk-in, but it is no longer offered to me.
    update bookings set offline_phone = null where id = b.id;
  end if;
  insert into notifications (user_id, kind, body, link) values (v_owner, 'link_answer',
    case when p_accept then format('ربط %s تسجيل %s بحسابه.', v_me, b.offline_name)
         else format('صاحب الرقم المسجّل للطالب %s قال إنه ليس ولي أمره. تأكد من الرقم.', b.offline_name) end,
    '/manage/course/' || b.offering_id);
end $$;

-- A new number on Classi: tell its owner about walk-ins carrying it (not the institute: that would reveal who joined).
create or replace function public.profiles_walkin_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.phone is null or (tg_op = 'UPDATE' and new.phone is not distinct from old.phone) then return new; end if;
  insert into notifications (user_id, kind, body, link)
  select new.id, 'link_request',
         format('%s سجّل الطالب %s في %s برقم هاتفك. اربط التسجيل بحسابك من جدولك.', coalesce(i.name, t.name), b.offline_name, o.title),
         '/schedule#links'
    from bookings b join offerings o on o.id = b.offering_id
    left join institutes i on i.id = o.institute_id left join teachers t on t.id = o.teacher_id
   where b.booked_by is null and b.offline_phone = new.phone and b.status in ('pending','confirmed');
  return new;
end $$;

-- owner_bookings: can_link no longer says whether the number has an account.
create or replace function public.owner_bookings(p_offering uuid default null)
returns table (booking_id uuid, offering_id uuid, offering_title text, offering_type offering_type, student_name text, starts_at timestamptz,
               session_id uuid, status booking_status, pay_method text, created_at timestamptz, mode place_kind, weekly boolean, series_id uuid,
               series_count int, price int, pay_status text, installments_total int, installments_paid int, offline boolean, offline_phone text,
               can_link boolean)
language sql stable security definer set search_path = public as $$
  select b.id, o.id, o.title, o.type,
         coalesce(c.name, b.offline_name, p.full_name, 'طالب'), coalesce(b.starts_at, s.starts_at), b.session_id,
         b.status, b.pay_method, b.created_at, b.mode, b.weekly, b.series_id,
         case when b.series_id is null then null
              else (select count(*)::int from bookings x where x.series_id = b.series_id and x.status in ('pending','confirmed')) end,
         b.price, b.pay_status, b.installments_total, b.installments_paid, b.booked_by is null, b.offline_phone,
         b.booked_by is null and b.offline_phone is not null and is_offering_owner(o.id)
  from bookings b
  join offerings o on o.id = b.offering_id
  left join children c on c.id = b.child_id
  left join profiles p on p.id = b.booked_by
  left join sessions s on s.id = b.session_id
  where is_offering_staff(o.id) and (p_offering is null or o.id = p_offering)
  order by coalesce(b.starts_at, s.starts_at, b.created_at)
$$;

------------------------------------------------------------------------------------------------------------
-- 4. SEC-02 / SEC-07 / SEC-08: SMS budget enforced in the database.
------------------------------------------------------------------------------------------------------------
create table if not exists public.sms_quota (user_id uuid not null, day date not null, n int not null default 0, primary key (user_id, day));
alter table public.sms_quota enable row level security;   -- no policies: only security-definer functions touch it
revoke all on public.sms_quota from anon, authenticated;

-- One more SMS for this person today? Per person (default 6/day) and platform-wide (default 400/day), both in app_settings.
create or replace function public.sms_allow(p_user uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_day date := (now() at time zone 'Asia/Jerusalem')::date;
        v_cap int := coalesce(nullif(setting('sms_daily_cap_per_user'), '')::int, 6);
        v_total_cap int := coalesce(nullif(setting('sms_daily_cap'), '')::int, 400);
        v_total int; v_n int;
begin
  select coalesce(sum(n), 0) into v_total from sms_quota where day = v_day;
  if v_total >= v_total_cap then
    insert into reminder_log (key) values ('sms-cap:' || v_day) on conflict do nothing;
    if found then
      perform notify_admins(format('وصلت رسائل SMS اليوم إلى الحد الأعلى (%s). الرسائل الإضافية تصل كإشعار في التطبيق فقط حتى الغد. يمكن تغيير الحد من الإعدادات (sms_daily_cap).', v_total_cap), '/admin?tab=ops');
    end if;
    return false;
  end if;
  insert into sms_quota (user_id, day, n) values (p_user, v_day, 1)
  on conflict (user_id, day) do update set n = sms_quota.n + 1 where sms_quota.n < v_cap
  returning n into v_n;
  return v_n is not null;
end $$;

create or replace function public.claim_push(p_secret text, p_limit int default 200)
returns jsonb language plpgsql security definer set search_path = public as $$
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
           -- nested CASE: the quota is only spent when an SMS would really be sent
           'phone', case when pk.kind = any(sms_kinds()) and pr.sms_ok and pr.phone is not null and is_active_user(pr.id)
                         then case when sms_allow(pr.id) then pr.phone end end,
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

-- Sign-in codes: Israeli mobile numbers only, at most 5 an hour and 15 a day per number.
-- A phone-change code is never emailed (the email belongs to the requesting account, not to the number's owner).
create table if not exists public.otp_requests (phone text not null, created_at timestamptz not null default now());
create index if not exists otp_requests_phone_time on public.otp_requests (phone, created_at);
alter table public.otp_requests enable row level security;
revoke all on public.otp_requests from anon, authenticated;

create or replace function public.send_sms_hook(event jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_type text := event->'sms'->>'sms_type';
  v_phone text := coalesce(nullif(event->'sms'->>'phone', ''),
                           case when v_type = 'phone_change' then nullif(event->'user'->>'phone_change', '') end,
                           nullif(event->'user'->>'phone', ''),
                           nullif(event->'user'->>'phone_change', ''));
  v_digits text := regexp_replace(coalesce(v_phone, ''), '\D', '', 'g');
  v_otp text := event->'sms'->>'otp'; v_url text; v_secret text;
begin
  if v_digits = '' or coalesce(v_otp, '') = '' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'missing phone or code'));
  end if;
  if v_digits !~ '^9725\d{8}$' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 400, 'message', 'Classi يعمل بأرقام الجوال الإسرائيلية فقط (05x)'));
  end if;
  delete from otp_requests where created_at < now() - interval '2 days';
  if (select count(*) from otp_requests where phone = v_digits and created_at > now() - interval '1 hour')
       >= coalesce(nullif(setting('otp_per_hour'), '')::int, 5)
     or (select count(*) from otp_requests where phone = v_digits and created_at > now() - interval '1 day')
       >= coalesce(nullif(setting('otp_per_day'), '')::int, 15) then
    return jsonb_build_object('error', jsonb_build_object('http_code', 429, 'message', 'طلبت رموزاً كثيرة لهذا الرقم. حاول بعد ساعة.'));
  end if;
  insert into otp_requests (phone) values (v_digits);
  delete from otp_outbox where created_at < now() - interval '15 minutes';
  insert into otp_outbox (phone, body, email, otp)
  values (v_phone, format('%s هو رمز الدخول إلى Classi. صالح 5 دقائق. لا تشاركه مع أحد.', v_otp),
          case when coalesce(v_type, '') <> 'phone_change' then nullif(event->'user'->>'email', '') end, v_otp);
  select regexp_replace(value, '/api/.*$', '/api/sms/otp') into v_url from app_secrets where key = 'dispatch_url';
  select value into v_secret from app_secrets where key = 'dispatch_secret';
  if v_url is not null and v_secret is not null then
    perform net.http_post(url := v_url, body := jsonb_build_object('secret', v_secret),
                          headers := '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 15000);
  end if;
  return '{}'::jsonb;
exception when others then
  return jsonb_build_object('error', jsonb_build_object('http_code', 500, 'message', 'تعذّر إرسال الرمز، حاول بعد قليل'));
end $$;

------------------------------------------------------------------------------------------------------------
-- 5. Booking rules the database enforces for students (SEC-14 / 15 / 17 / 22 / 24 / 27, SEC-07)
------------------------------------------------------------------------------------------------------------
create or replace function public.bookings_zzz_rules() returns trigger
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_local timestamp; v_end timestamp; v_n int;
begin
  -- Only bookings a student makes for themselves; teachers, institutes, walk-ins and scheduled jobs are not limited here.
  if auth.uid() is null or new.booked_by is distinct from auth.uid() then return new; end if;
  select * into o from offerings where id = new.offering_id;
  if is_offering_owner(o.id) or is_admin() then return new; end if;

  if new.pay_method is null or new.pay_method not in ('bit','cash','card','installments','package') then
    raise exception 'طريقة دفع غير معروفة';
  end if;
  if new.pay_method = 'package' and new.package_id is null then
    raise exception 'لا توجد رزمة فعّالة لهذا الطالب مع هذا العرض';
  end if;

  if o.type = 'private' and new.starts_at is not null then
    if o.teacher_id is not null then
      -- inside the teacher's published hours (Israel time)
      v_local := new.starts_at at time zone 'Asia/Jerusalem';
      v_end := v_local + make_interval(mins => coalesce(new.minutes, o.minutes));
      if not exists (select 1 from availability a
                      where a.teacher_id = o.teacher_id and a.weekday = extract(dow from v_local)::int
                        and a.start_time <= v_local::time and v_end::date = v_local::date and v_end::time <= a.end_time) then
        raise exception 'هذا الموعد خارج ساعات المعلم المتاحة';
      end if;
    else
      -- private lessons of an institute: one booking per time slot of that offer
      perform pg_advisory_xact_lock(hashtext('offering:' || o.id::text));
      if exists (select 1 from bookings b where b.offering_id = o.id and b.status in ('pending','confirmed') and b.starts_at is not null
                   and tstzrange(b.starts_at, b.starts_at + make_interval(mins => b.minutes))
                    && tstzrange(new.starts_at, new.starts_at + make_interval(mins => coalesce(new.minutes, o.minutes)))) then
        raise exception 'الموعد لم يعد متاحاً، اختر موعداً آخر';
      end if;
    end if;
    if new.series_id is null then
      select count(*) into v_n from bookings b where b.offering_id = o.id and b.booked_by = auth.uid()
         and b.status in ('pending','confirmed') and b.series_id is null and b.starts_at > now();
      if v_n >= coalesce(nullif(setting('max_open_bookings_per_offer'), '')::int, 8) then
        raise exception 'لديك حجوزات قادمة كثيرة مع هذا العرض. للمواعيد الثابتة استخدم الحجز الأسبوعي.';
      end if;
    end if;
  elsif o.type = 'group' and new.session_id is not null then
    if exists (select 1 from bookings b where b.session_id = new.session_id and b.booked_by = auth.uid()
                 and b.child_id is not distinct from new.child_id and b.status in ('pending','confirmed')) then
      raise exception 'هذا الطالب مسجّل في هذا اللقاء';
    end if;
  elsif o.type in ('course','recorded') then
    if exists (select 1 from bookings b where b.offering_id = o.id and b.session_id is null and b.booked_by = auth.uid()
                 and b.child_id is not distinct from new.child_id and b.status in ('pending','confirmed')) then
      raise exception 'هذا الطالب مسجّل في هذا العرض';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists bookings_zzz_rules on public.bookings;
create trigger bookings_zzz_rules before insert on public.bookings for each row execute function bookings_zzz_rules();

-- SEC-14 (no cancelling a lesson that already happened) and SEC-07 (a booking withdrawn within 2 hours of
-- being made tells the teacher in the app, not by SMS).
create or replace function public.cancel_booking(p_booking uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_owner uuid; v_title text; v_start timestamptz;
begin
  select * into b from bookings where id = p_booking and booked_by = auth.uid() for update;
  if not found then raise exception 'الحجز غير موجود'; end if;
  if b.status not in ('pending','confirmed') then raise exception 'الحجز ملغى سابقاً'; end if;
  v_start := coalesce(b.starts_at,
                      (select starts_at from sessions where id = b.session_id),
                      (select min(starts_at) from sessions where offering_id = b.offering_id and not cancelled and b.session_id is null));
  if b.status = 'confirmed' and v_start is not null and v_start <= now() then
    raise exception 'لا يمكن إلغاء حصة أو دورة بدأت. تواصل مع المعلم أو المعهد.';
  end if;
  if b.starts_at is not null and b.starts_at < now() + interval '24 hours' and b.status = 'confirmed' and b.changed_at is null then
    raise exception 'الإلغاء المجاني متاح حتى 24 ساعة قبل الحصة. تواصل مع المعلم.';
  end if;
  update bookings set status = 'cancelled' where id = p_booking;
  v_owner := offering_owner_user(b.offering_id);
  select title into v_title from offerings where id = b.offering_id;
  if v_owner is not null then
    insert into notifications (user_id, kind, body, link) values (v_owner,
      case when b.created_at > now() - interval '2 hours' then 'booking_withdrawn' else 'booking_cancelled' end,
      format('أُلغي حجز: %s%s', v_title, coalesce('، ' || fmt_time(b.starts_at), '')), '/teach');
  end if;
end $$;

-- SEC-15: a review only after the lesson ended; a review whose booking is cancelled is hidden.
create or replace function public.leave_review(p_booking uuid, p_stars int, p_body text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare b record; v_id uuid; v_owner uuid; v_new boolean;
begin
  if p_stars not between 1 and 5 then raise exception 'اختر من 1 إلى 5 نجوم'; end if;
  if char_length(coalesce(p_body, '')) > 1000 then raise exception 'التعليق طويل جداً (1000 حرف كحد أقصى)'; end if;
  select bk.id, bk.child_id, o.teacher_id, o.institute_id, o.title, bk.minutes,
         coalesce(bk.starts_at, s.starts_at, (select min(x.starts_at) from sessions x where x.offering_id = o.id and not x.cancelled)) at
    into b
    from bookings bk join offerings o on o.id = bk.offering_id left join sessions s on s.id = bk.session_id
   where bk.id = p_booking and bk.booked_by = auth.uid() and bk.status = 'confirmed';
  if b.id is null then raise exception 'يمكنك تقييم حصة حجزتها فقط'; end if;
  if b.at is null or b.at + make_interval(mins => coalesce(b.minutes, 60)) > now() then
    raise exception 'يمكنك التقييم بعد انتهاء الحصة الأولى';
  end if;
  select id into v_id from reviews where user_id = auth.uid() and child_id is not distinct from b.child_id
     and coalesce(teacher_id, institute_id) = coalesce(b.teacher_id, b.institute_id);
  v_new := v_id is null;
  if v_new then
    insert into reviews (booking_id, stars, body, user_id, child_id, teacher_id, institute_id, author_name)
    values (b.id, p_stars, nullif(trim(p_body), ''), auth.uid(), b.child_id, b.teacher_id, b.institute_id,
            array_to_string((string_to_array(trim(coalesce((select full_name from profiles where id = auth.uid()), '')), ' '))[1:2], ' '))
    returning id into v_id;
  else
    update reviews set stars = p_stars, body = nullif(trim(p_body), ''), updated_at = now() where id = v_id;
  end if;
  v_owner := coalesce((select user_id from teachers where id = b.teacher_id), (select owner_id from institutes where id = b.institute_id));
  if v_owner is not null and v_new then
    insert into notifications (user_id, kind, body, link)
    values (v_owner, 'review_new', format('تقييم جديد %s نجوم: %s%s', p_stars, b.title, coalesce(' «' || left(nullif(trim(p_body), ''), 60) || '»', '')),
            case when b.teacher_id is not null then '/teach#reviews' else '/manage#reviews' end);
  end if;
  return v_id;
end $$;

create or replace function public.bookings_hide_reviews() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    update reviews set hidden = true where booking_id = new.id and not hidden;
  end if;
  return null;
end $$;
drop trigger if exists bookings_hide_reviews on public.bookings;
create trigger bookings_hide_reviews after update of status on public.bookings for each row execute function bookings_hide_reviews();

-- SEC-24: payment numbers only for live bookings and packages.
create or replace function public.my_pay_numbers()
returns table (offering_id uuid, owner_name text, bit_phone text)
language sql stable security definer set search_path = public as $$
  select o.id, coalesce(t.name, i.name), coalesce(pt.bit_phone, pi.bit_phone)
    from offerings o left join teachers t on t.id = o.teacher_id left join institutes i on i.id = o.institute_id
    left join pay_numbers pt on pt.teacher_id = o.teacher_id left join pay_numbers pi on pi.institute_id = o.institute_id
   where o.id in (select b.offering_id from bookings b where b.booked_by = auth.uid() and b.status in ('pending','confirmed')
                  union select p.offering_id from lesson_packages p where p.user_id = auth.uid() and p.status <> 'cancelled')
$$;

-- SEC-21: confirmations lock the row, so two quick taps cannot count the same installment twice.
create or replace function public.confirm_payment(p_booking uuid default null, p_package uuid default null, p_received boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare v_off uuid; v_user uuid; v_amount int; v_title text; v_was text; v_total int; v_paid int; v_this int;
begin
  if p_booking is not null then
    select offering_id, booked_by, price, pay_status, installments_total, installments_paid
      into v_off, v_user, v_amount, v_was, v_total, v_paid from bookings where id = p_booking for update;
  else
    select offering_id, user_id, price, pay_status, 1, 0 into v_off, v_user, v_amount, v_was, v_total, v_paid
      from lesson_packages where id = p_package for update;
  end if;
  if v_off is null or not is_offering_owner(v_off) then raise exception 'لا تملك صلاحية على هذا الحجز'; end if;
  if v_was not in ('unpaid','reported','paid') then raise exception 'هذه الحصة لا تحتاج دفعاً (مجانية أو ضمن رزمة)'; end if;
  select title into v_title from offerings where id = v_off;

  if p_booking is not null and v_total > 1 then
    v_this := installment_amount(v_amount, v_total, v_paid);
    if p_received then
      if v_paid >= v_total then raise exception 'كل الدفعات مستلمة'; end if;
      update bookings set installments_paid = installments_paid + 1,
             pay_status = case when installments_paid + 1 >= installments_total then 'paid' else 'unpaid' end,
             paid_at = case when installments_paid + 1 >= installments_total then now() else paid_at end,
             reported_at = null
       where id = p_booking;
    else
      update bookings set pay_status = 'unpaid', reported_at = null where id = p_booking;
    end if;
    if v_was = 'reported' or p_received then
      insert into notifications (user_id, kind, body, link) values (v_user, 'payment_answer',
        case when p_received then format('استلمنا الدفعة %s من %s (%s ₪): %s.%s', v_paid + 1, v_total, v_this, v_title,
                                         case when v_paid + 1 >= v_total then ' تم دفع الدورة كاملة، شكراً!' else '' end)
             else format('لم تصل الدفعة %s من %s (%s ₪) بعد: %s.', v_paid + 1, v_total, v_this, v_title) end,
        '/schedule');
    end if;
    return;
  end if;

  if p_booking is not null then
    update bookings set pay_status = case when p_received then 'paid' else 'unpaid' end,
                        paid_at = case when p_received then now() end,
                        reported_at = case when p_received then reported_at end
     where id = p_booking;
  else
    update lesson_packages set pay_status = case when p_received then 'paid' else 'unpaid' end,
                               paid_at = case when p_received then now() end,
                               reported_at = case when p_received then reported_at end
     where id = p_package;
  end if;
  if v_was = 'reported' then
    insert into notifications (user_id, kind, body, link) values (v_user, 'payment_answer',
      case when p_received then format('أكّد المعلم استلام %s ₪: %s. شكراً!', v_amount, v_title)
           else format('لم يصل تحويل %s ₪ للمعلم بعد: %s. تأكد من رقم Bit وحاول مرة أخرى.', v_amount, v_title) end,
      '/schedule');
  end if;
end $$;
do $$ begin
  alter table public.bookings add constraint bookings_installments_le_total check (installments_paid <= installments_total) not valid;
exception when duplicate_object then null; end $$;

------------------------------------------------------------------------------------------------------------
-- 6. SEC-16 / SEC-31 policies
------------------------------------------------------------------------------------------------------------
-- Recorded-course content is released once the booking is paid (or free / from a package).
drop policy if exists "confirmed students read links" on public.offering_links;
create policy "confirmed students read links" on public.offering_links for select using (
  exists (select 1 from bookings b join offerings o on o.id = b.offering_id
           where b.offering_id = offering_links.offering_id and b.booked_by = auth.uid() and b.status = 'confirmed'
             and (o.type <> 'recorded' or b.pay_status not in ('unpaid','reported'))));

-- Attendance rows must belong to a booking of the same offer as the session.
drop policy if exists "staff attendance" on public.attendance;
create policy "staff attendance" on public.attendance for all
  using (exists (select 1 from sessions s where s.id = attendance.session_id and is_offering_staff(s.offering_id)))
  with check (exists (select 1 from sessions s join bookings b on b.offering_id = s.offering_id
                       where s.id = attendance.session_id and b.id = attendance.booking_id and is_offering_staff(s.offering_id)));

------------------------------------------------------------------------------------------------------------
-- 7. SEC-05 / SEC-18: deleting an offer, a meeting or an account never erases the other side's records.
------------------------------------------------------------------------------------------------------------
-- Owners can delete only offers and meetings nobody booked (otherwise: hide / cancel, which keeps history).
drop policy if exists "owner deletes offerings" on public.offerings;
create policy "owner deletes offerings" on public.offerings for delete using (
  is_offering_owner(id)
  and not exists (select 1 from bookings b where b.offering_id = offerings.id)
  and not exists (select 1 from lesson_packages p where p.offering_id = offerings.id)
  and not exists (select 1 from reviews r join bookings b on b.id = r.booking_id where b.offering_id = offerings.id));
drop policy if exists "owner deletes sessions" on public.sessions;
create policy "owner deletes sessions" on public.sessions for delete using (
  is_offering_owner(offering_id)
  and not exists (select 1 from bookings b where b.session_id = sessions.id)
  and not exists (select 1 from attendance a where a.session_id = sessions.id)
  and not exists (select 1 from lesson_reports r where r.session_id = sessions.id));

-- Backstop at the foreign-key level: history rows block the delete instead of vanishing with it.
do $$
declare r record; k record;
begin
  for r in select * from (values
      ('bookings','offering_id','offerings','restrict'), ('bookings','session_id','sessions','restrict'),
      ('lesson_reports','booking_id','bookings','restrict'), ('lesson_reports','offering_id','offerings','restrict'),
      ('lesson_reports','session_id','sessions','restrict'), ('attendance','booking_id','bookings','restrict'),
      ('attendance','session_id','sessions','restrict'), ('lesson_packages','offering_id','offerings','restrict'),
      ('recurring_series','offering_id','offerings','restrict'), ('reviews','booking_id','bookings','set null'),
      -- account deletion: keep the other side's records, without the person
      ('bookings','booked_by','profiles','set null'), ('lesson_packages','user_id','profiles','set null'),
      ('recurring_series','booked_by','profiles','set null'), ('lesson_reports','author_id','profiles','set null'),
      ('lesson_reports','student_user','profiles','set null'), ('change_log','changed_by','profiles','set null'),
      ('moderation_actions','admin_id','profiles','set null'), ('reports','resolved_by','profiles','set null')
    ) v(tbl, col, ref, action) loop
    for k in select c.conname from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
              where c.contype = 'f' and c.conrelid = ('public.' || r.tbl)::regclass and a.attname = r.col loop
      execute format('alter table public.%I drop constraint %I', r.tbl, k.conname);
    end loop;
    if r.action = 'set null' then execute format('alter table public.%I alter column %I drop not null', r.tbl, r.col); end if;
    execute format('alter table public.%I add constraint %I foreign key (%I) references public.%I(id) on delete %s',
                   r.tbl, r.tbl || '_' || r.col || '_fkey', r.col, r.ref, r.action);
  end loop;
end $$;

create or replace function public.delete_my_account(p_confirm text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid(); b record;
begin
  if v_uid is null then raise exception 'سجّل الدخول أولاً'; end if;
  if trim(coalesce(p_confirm, '')) <> 'احذف' then raise exception 'اكتب كلمة «احذف» للتأكيد'; end if;
  perform set_config('classi.bypass_review', 'on', true);
  perform set_config('classi.bypass_active', 'on', true);   -- a suspended person may still delete their account

  -- Future lessons booked by this account are cancelled and the teachers told.
  for b in select bk.id from bookings bk left join sessions s on s.id = bk.session_id
            where bk.booked_by = v_uid and bk.status in ('pending','confirmed') and coalesce(bk.starts_at, s.starts_at, now() + interval '1 day') > now() loop
    update bookings set status = 'cancelled' where id = b.id;
  end loop;
  update recurring_series set status = 'cancelled', cancelled_at = now() where booked_by = v_uid and status <> 'cancelled';

  -- A teacher or institute leaving: their profile and offers disappear, their students are told.
  insert into notifications (user_id, kind, body, link)
  select distinct bk.booked_by, 'booking_cancelled', format('أُغلق حساب %s في Classi، وأُلغيت الحصص القادمة معه.', coalesce(t.name, i.name)), '/search'
    from bookings bk join offerings o on o.id = bk.offering_id
    left join teachers t on t.id = o.teacher_id left join institutes i on i.id = o.institute_id
    left join sessions s on s.id = bk.session_id
   where (t.user_id = v_uid or i.owner_id = v_uid) and bk.status in ('pending','confirmed')
     and coalesce(bk.starts_at, s.starts_at, now() + interval '1 day') > now() and bk.booked_by <> v_uid;
  -- Only future lessons are cancelled; past lessons stay as they were (they are the other side's history).
  update bookings bk set status = 'cancelled' from offerings o
   where o.id = bk.offering_id and bk.status in ('pending','confirmed')
     and coalesce(bk.starts_at, (select starts_at from sessions s where s.id = bk.session_id), now() + interval '1 day') > now()
     and (o.teacher_id in (select id from teachers where user_id = v_uid) or o.institute_id in (select id from institutes where owner_id = v_uid));
  update offerings set active = false
   where teacher_id in (select id from teachers where user_id = v_uid) or institute_id in (select id from institutes where owner_id = v_uid);
  update teachers set moderation_hidden = true, verify = 'rejected', bio = '', photo_url = null, intro_video_url = null where user_id = v_uid;
  update institutes set moderation_hidden = true, verify = 'rejected', bio = '', logo_url = null where owner_id = v_uid;
  delete from pay_numbers where teacher_id in (select id from teachers where user_id = v_uid) or institute_id in (select id from institutes where owner_id = v_uid);
  delete from push_subscriptions where user_id = v_uid;

  -- The teacher keeps the lesson and payment record, without the person's name or number.
  update bookings set offline_name = 'حساب محذوف', offline_phone = null where booked_by = v_uid;

  -- The sign-in account goes; personal rows follow by cascade, shared records are kept without the person.
  delete from auth.users where id = v_uid;
end $$;

------------------------------------------------------------------------------------------------------------
-- 8. SEC-06 / SEC-19 / SEC-20 / SEC-28 column-level protection
------------------------------------------------------------------------------------------------------------
-- Notifications: a user may only mark them read (not rewrite them and have them sent again as SMS).
revoke update on public.notifications from anon, authenticated;
grant update (read_at) on public.notifications to authenticated;

-- Anonymous visitors: no internal columns (moderation notes, unapproved edits, private ids on reviews).
do $$
declare r record; v_cols text;
begin
  for r in select * from (values
      ('teachers', array['pending_changes','review_note']),
      ('institutes', array['pending_changes','review_note']),
      ('offerings', array['pending_changes','review_note']),
      ('reviews', array['booking_id','user_id','child_id'])) v(tbl, hidden) loop
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
      from information_schema.columns where table_schema = 'public' and table_name = r.tbl and column_name <> all (r.hidden);
    execute format('revoke select on public.%I from anon', r.tbl);
    execute format('grant select (%s) on public.%I to anon', v_cols, r.tbl);
  end loop;
end $$;

-- Photo links must point at Classi's own storage bucket (checked for new and changed rows).
do $$ begin
  alter table public.teachers add constraint teachers_photo_url_chk
    check (photo_url is null or photo_url ~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/') not valid;
  alter table public.institutes add constraint institutes_logo_url_chk
    check (logo_url is null or logo_url ~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/') not valid;
  alter table public.profiles add constraint profiles_avatar_url_chk
    check (avatar_url is null or avatar_url ~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/') not valid;
exception when duplicate_object then null; end $$;

------------------------------------------------------------------------------------------------------------
-- 9. SEC-01: least privilege on functions. Supabase grants EXECUTE on every new function to anon and
-- authenticated; take that away and grant back only what the app calls (and what RLS policies use).
------------------------------------------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
do $$ begin
  -- Supabase creates objects as "postgres"; make the default stick for that role too.
  if exists (select 1 from pg_roles where rolname = 'postgres') then
    execute 'alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated';
    -- PostgreSQL's built-in default (EXECUTE for PUBLIC) is global, not per schema
    execute 'alter default privileges for role postgres revoke execute on functions from public';
  end if;
end $$;

do $$
declare
  -- used inside RLS policies: every role that reads those tables needs them
  v_policy text[] := array['is_active_user','is_admin','is_conversation_member','is_conversation_reported','is_offering_owner',
                           'is_offering_staff','my_teacher_id','offering_owner_verified','owner_has_access'];
  -- public pages and the server routes that use the anon key (the dispatch routes check a secret inside)
  v_anon text[] := array['setting','seats_overview','teacher_busy','teacher_buffer','health_ping',
                         'claim_otp','claim_push','log_sms','drop_push_subscriptions'];
  -- everything the signed-in app calls (grep "rpc(" in app/, lib/, components/)
  v_auth text[] := array['admin_activate_subscription','admin_cancel_booking','admin_close_report','admin_demo_visible','admin_edit_offer',
    'admin_find_bookings','admin_grant_subscription','admin_hide','admin_hide_review','admin_message','admin_reports','admin_review',
    'admin_review_queue','admin_set_payment','admin_set_plan','admin_set_setting','admin_set_user_status','admin_sms_stats','admin_stats',
    'admin_subscriptions','admin_users','admin_verify','buy_package','cancel_booking','cancel_package','cancel_series','cancel_session',
    'confirm_payment','create_booking','create_trial_booking','create_weekly_booking','delete_my_account','institute_enroll',
    'institute_link_booking','institute_remove_staff','join_waitlist','leave_review','leave_waitlist','mark_conversation_read',
    'mark_report_read','my_conversations','my_header_counts','my_pay_numbers','my_reports','my_students','my_teacher_calendar',
    'my_waitlist','owner_bookings','owner_money_summary','owner_packages','owner_payments','owner_waitlist','paid_until',
    'pending_reports','remove_push_subscription','reply_review','report_payment','report_subscription_payment','request_subscription',
    'reschedule_session','respond_booking','respond_waitlist','save_push_subscription','session_students','set_bit_phone',
    'start_conversation','start_conversation_for_booking','teacher_add_booking','teacher_block','teacher_cancel_booking',
    'teacher_move_booking','teacher_unblock','teacher_vacation','trial_available','waitlist_hours_opened','write_lesson_report',
    'write_session_reports',
    -- new in this migration
    'my_staff_invites','answer_staff_invite','my_link_requests','accept_booking_link'];
  f record;
begin
  for f in select p.oid, p.proname from pg_proc p where p.pronamespace = 'public'::regnamespace loop
    if f.proname = any(v_policy || v_anon) then
      execute format('grant execute on function %s to anon, authenticated', f.oid::regprocedure);
    elsif f.proname = any(v_auth) then
      execute format('grant execute on function %s to authenticated', f.oid::regprocedure);
    end if;
  end loop;
end $$;
-- The Auth hook keeps its own grant (to supabase_auth_admin, set in 20261026050000_phone_login.sql).
