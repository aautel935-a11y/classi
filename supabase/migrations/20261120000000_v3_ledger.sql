-- Classi v3 · customer payments ledger (decision of 19/11/2026).
-- Customers pay the business directly, OUTSIDE Classi (cash, Bit, PayBox, bank transfer, cheque, anything agreed).
-- Classi holds no money, processes no cards and issues no tax documents: this is an administrative record of what the
-- business says it received. Every screen and export says so.
--
--   charges   one amount owed (linked to a booking, a lesson package, or entered by hand)
--   payments  APPEND-ONLY entries against a charge: payment, deposit, refund, and void (a documented correction that
--             cancels one earlier entry). No UPDATE or DELETE for any role; a trigger refuses them even for the
--             service role. Paid / remaining / status are always computed, never stored.
--   audit_log append-only record of every sensitive change (who, what, before, after, why).
--   staff_permissions  what an institute's staff (accepted institute_teachers) may do with the ledger.
--
-- Additive: no existing table, column or function changes. The current pay_status flow keeps working.
-- All reads and writes go through SECURITY DEFINER functions that take the business from the caller's session.

-- ================= tables =================
create table if not exists public.charges (
  id             uuid primary key default gen_random_uuid(),
  teacher_id     uuid references public.teachers(id) on delete cascade,
  institute_id   uuid references public.institutes(id) on delete cascade,
  customer_id    uuid references public.profiles(id) on delete set null,   -- the customer's account, when there is one
  customer_label text not null check (length(trim(customer_label)) between 1 and 80),
  source_kind    text not null default 'manual' check (source_kind in ('manual','booking','package')),
  source_id      uuid,
  description    text not null check (length(trim(description)) between 1 and 200),
  amount         numeric(12,2) not null check (amount > 0 and amount <= 1000000),
  deposit_amount numeric(12,2) check (deposit_amount is null or (deposit_amount > 0 and deposit_amount <= amount)),
  due_on         date,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  cancelled_at   timestamptz,
  cancelled_by   uuid,
  cancel_reason  text,
  constraint charges_one_owner check ((teacher_id is null) <> (institute_id is null)),
  constraint charges_source check ((source_kind = 'manual') = (source_id is null)),
  constraint charges_cancel check ((cancelled_at is null) = (cancel_reason is null))
);
create unique index if not exists charges_one_per_source on public.charges (source_kind, source_id) where source_id is not null;
create index if not exists charges_teacher on public.charges (teacher_id, created_at desc) where teacher_id is not null;
create index if not exists charges_institute on public.charges (institute_id, created_at desc) where institute_id is not null;
create index if not exists charges_customer on public.charges (customer_id) where customer_id is not null;

create table if not exists public.payments (
  id           uuid primary key default gen_random_uuid(),
  charge_id    uuid not null references public.charges(id) on delete cascade,
  kind         text not null check (kind in ('payment','deposit','refund','void')),
  amount       numeric(12,2) not null check (amount > 0),
  method       text check (method in ('cash','bit','paybox','bank_transfer','cheque','other')),
  paid_on      date,
  note         text check (note is null or length(note) <= 300),
  voids        uuid unique references public.payments(id),
  recorded_by  uuid,                 -- no foreign key: an entry must outlive the account that wrote it
  recorded_by_name text,
  recorded_at  timestamptz not null default now(),
  constraint payments_void_shape check ((kind = 'void') = (voids is not null)),
  constraint payments_money_shape check (kind = 'void' or (method is not null and paid_on is not null))
);
create index if not exists payments_charge on public.payments (charge_id, recorded_at);

create table if not exists public.audit_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor        uuid,
  teacher_id   uuid,
  institute_id uuid,
  action       text not null,
  entity       text not null,
  entity_id    uuid,
  before       jsonb,
  after        jsonb,
  reason       text
);
create index if not exists audit_log_business on public.audit_log (coalesce(teacher_id, institute_id), at desc);

create table if not exists public.staff_permissions (
  institute_id uuid not null references public.institutes(id) on delete cascade,
  teacher_id   uuid not null references public.teachers(id) on delete cascade,
  permission   text not null check (permission in ('payments.record','payments.correct','payments.reports')),
  granted_by   uuid,
  granted_at   timestamptz not null default now(),
  primary key (institute_id, teacher_id, permission)
);

-- No direct access for anon/authenticated: RLS on, no policies, no grants. Everything goes through the functions below.
alter table public.charges enable row level security;
alter table public.payments enable row level security;
alter table public.audit_log enable row level security;
alter table public.staff_permissions enable row level security;
revoke all on public.charges, public.payments, public.audit_log, public.staff_permissions from anon, authenticated;

-- Append-only: refuse UPDATE and DELETE on payments and audit_log for every role (service role and table owner too).
create or replace function public.ledger_append_only() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  raise exception 'سجل الدفعات لا يُعدَّل ولا يُحذف. سجّل تصحيحاً موثقاً بدلاً من ذلك.' using errcode = '42501';
end $$;
drop trigger if exists payments_append_only on public.payments;
create trigger payments_append_only before update or delete on public.payments
  for each row execute function public.ledger_append_only();
drop trigger if exists audit_log_append_only on public.audit_log;
create trigger audit_log_append_only before update or delete on public.audit_log
  for each row execute function public.ledger_append_only();
revoke all on function public.ledger_append_only() from public, anon, authenticated;

-- ================= helpers (internal: not executable by anon/authenticated) =================
create or replace function public.ledger_is_owner(p_teacher uuid, p_institute uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and (
         (p_teacher is not null and exists (select 1 from teachers where id = p_teacher and user_id = auth.uid()))
      or (p_institute is not null and exists (select 1 from institutes where id = p_institute and owner_id = auth.uid())))
$$;

-- Staff = a teacher of the institute (accepted link) holding the permission.
create or replace function public.ledger_staff_can(p_institute uuid, p_permission text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and p_institute is not null and exists (
    select 1 from staff_permissions sp
      join institute_teachers it on it.institute_id = sp.institute_id and it.teacher_id = sp.teacher_id and it.status = 'accepted'
      join teachers t on t.id = sp.teacher_id and t.user_id = auth.uid()
     where sp.institute_id = p_institute and sp.permission = p_permission)
$$;

create or replace function public.ledger_can(p_teacher uuid, p_institute uuid, p_permission text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select ledger_is_owner(p_teacher, p_institute) or ledger_staff_can(p_institute, p_permission)
$$;

-- The caller's own business (a teacher profile first, else an institute they own). Used when the app does not say.
create or replace function public.ledger_my_business(out teacher_id uuid, out institute_id uuid)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  select t.id into teacher_id from teachers t where t.user_id = auth.uid() limit 1;
  if teacher_id is null then select i.id into institute_id from institutes i where i.owner_id = auth.uid() limit 1; end if;
end $$;

-- A digit run that passes the Luhn check (13–19 digits, spaces/dashes allowed) looks like a card number: never stored.
create or replace function public.ledger_looks_like_card(p text) returns boolean
language plpgsql immutable set search_path = public, pg_temp as $$
declare m text; d text; s int; i int; n int; dbl boolean;
begin
  if p is null then return false; end if;
  for m in select (regexp_matches(p, '(\d[\d \-]{11,24}\d)', 'g'))[1] loop
    d := regexp_replace(m, '[^0-9]', '', 'g');
    if length(d) between 13 and 19 then
      s := 0; dbl := false;
      for i in reverse length(d)..1 loop
        n := substr(d, i, 1)::int;
        if dbl then n := n * 2; if n > 9 then n := n - 9; end if; end if;
        s := s + n; dbl := not dbl;
      end loop;
      if s % 10 = 0 then return true; end if;
    end if;
  end loop;
  return false;
end $$;

create or replace function public.ledger_audit(p_teacher uuid, p_institute uuid, p_action text, p_entity text, p_id uuid,
                                               p_before jsonb, p_after jsonb, p_reason text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into audit_log (actor, teacher_id, institute_id, action, entity, entity_id, before, after, reason)
  values (auth.uid(), p_teacher, p_institute, p_action, p_entity, p_id, p_before, p_after, nullif(trim(p_reason), ''))
$$;

-- Totals of one charge. Voided entries (and the void rows themselves) do not count. Refunds subtract.
create or replace function public.ledger_paid(p_charge uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(case when p.kind = 'refund' then -p.amount else p.amount end), 0)
    from payments p
   where p.charge_id = p_charge and p.kind in ('payment','deposit','refund')
     and not exists (select 1 from payments v where v.voids = p.id)
$$;

-- unpaid · partial · paid · overdue · cancelled (cancelled first, then paid, then overdue, then partial/unpaid)
create or replace function public.ledger_status(p_charge uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when c.cancelled_at is not null then 'cancelled'
    when ledger_paid(c.id) >= c.amount then 'paid'
    when c.due_on is not null and c.due_on < (now() at time zone 'Asia/Jerusalem')::date then 'overdue'
    when ledger_paid(c.id) > 0 then 'partial'
    else 'unpaid' end
  from charges c where c.id = p_charge
$$;

revoke all on function public.ledger_is_owner(uuid, uuid), public.ledger_staff_can(uuid, text), public.ledger_can(uuid, uuid, text),
  public.ledger_my_business(), public.ledger_looks_like_card(text), public.ledger_audit(uuid, uuid, text, text, uuid, jsonb, jsonb, text),
  public.ledger_paid(uuid), public.ledger_status(uuid) from public, anon, authenticated;

-- ================= owner / staff: write =================
-- New charge. p_teacher / p_institute name the business; both null = the caller's own business.
create or replace function public.create_charge(p_teacher uuid, p_institute uuid, p_customer_label text, p_description text,
                                                p_amount numeric, p_due_on date default null, p_deposit numeric default null,
                                                p_customer uuid default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_t uuid := p_teacher; v_i uuid := p_institute; v_id uuid;
begin
  if v_t is null and v_i is null then select teacher_id, institute_id into v_t, v_i from ledger_my_business(); end if;
  if (v_t is null) = (v_i is null) then raise exception 'لا يوجد نشاط تجاري مرتبط بحسابك'; end if;
  if not ledger_can(v_t, v_i, 'payments.record') then raise exception 'ليست لديك صلاحية تسجيل المستحقات'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'المبلغ يجب أن يكون أكبر من صفر'; end if;
  if ledger_looks_like_card(p_description) or ledger_looks_like_card(p_customer_label) then
    raise exception 'لا تكتب أرقام بطاقات أو حسابات بنكية في Classi';
  end if;
  -- A charge shows up in a customer's account only if that customer really dealt with this business (a booking or a
  -- lesson package on its offers): no business can put a debt in a stranger's account.
  if p_customer is not null and not exists (
       select 1 from bookings b join offerings o on o.id = b.offering_id
        where b.booked_by = p_customer and ((v_t is not null and o.teacher_id = v_t) or (v_i is not null and o.institute_id = v_i))
       union all
       select 1 from lesson_packages k join offerings o on o.id = k.offering_id
        where k.user_id = p_customer and ((v_t is not null and o.teacher_id = v_t) or (v_i is not null and o.institute_id = v_i))) then
    raise exception 'هذا الزبون غير مرتبط بنشاطك';
  end if;
  insert into charges (teacher_id, institute_id, customer_id, customer_label, description, amount, deposit_amount, due_on, created_by)
  values (v_t, v_i, p_customer, trim(p_customer_label), trim(p_description), round(p_amount, 2), round(p_deposit, 2), p_due_on, auth.uid())
  returning id into v_id;
  perform ledger_audit(v_t, v_i, 'charge_create', 'charge', v_id, null,
    jsonb_build_object('amount', round(p_amount, 2), 'deposit', round(p_deposit, 2), 'due_on', p_due_on, 'label', trim(p_customer_label)), null);
  return v_id;
end $$;

-- A charge for an existing booking (its price, its customer), once per booking. Returns the existing one if there is one.
create or replace function public.charge_for_booking(p_booking uuid, p_due_on date default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare b record; v_id uuid;
begin
  select bk.id, bk.booked_by, coalesce(bk.price, o.price) price, o.teacher_id, o.institute_id, o.title,
         coalesce(ch.name, p.full_name, 'زبون') who, coalesce(bk.starts_at, s.starts_at) at
    into b
    from bookings bk join offerings o on o.id = bk.offering_id
    left join children ch on ch.id = bk.child_id left join profiles p on p.id = bk.booked_by
    left join sessions s on s.id = bk.session_id
   where bk.id = p_booking;
  if not found or not ledger_can(b.teacher_id, b.institute_id, 'payments.record') then raise exception 'الحجز غير موجود'; end if;
  select id into v_id from charges where source_kind = 'booking' and source_id = p_booking;
  if v_id is not null then return v_id; end if;
  if coalesce(b.price, 0) <= 0 then raise exception 'هذا الحجز بلا سعر'; end if;
  insert into charges (teacher_id, institute_id, customer_id, customer_label, source_kind, source_id, description, amount, due_on, created_by)
  values (b.teacher_id, b.institute_id, b.booked_by, left(b.who, 80), 'booking', p_booking,
          left(b.title || coalesce(' · ' || to_char(b.at at time zone 'Asia/Jerusalem', 'DD/MM HH24:MI'), ''), 200), b.price,
          coalesce(p_due_on, (b.at at time zone 'Asia/Jerusalem')::date), auth.uid())
  returning id into v_id;
  perform ledger_audit(b.teacher_id, b.institute_id, 'charge_create', 'charge', v_id, null,
    jsonb_build_object('amount', b.price, 'booking', p_booking), null);
  return v_id;
end $$;

-- One payment / deposit / refund. Over-payment is refused unless p_allow_over with a note.
create or replace function public.record_payment(p_charge uuid, p_kind text, p_amount numeric, p_method text,
                                                 p_paid_on date default null, p_note text default null,
                                                 p_allow_over boolean default false) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c charges%rowtype; v_id uuid; v_paid numeric; v_amt numeric := round(coalesce(p_amount, 0), 2);
        v_on date := coalesce(p_paid_on, (now() at time zone 'Asia/Jerusalem')::date);
begin
  select * into c from charges where id = p_charge for update;
  if not found or not ledger_can(c.teacher_id, c.institute_id, 'payments.record') then raise exception 'المستحق غير موجود'; end if;
  if c.cancelled_at is not null then raise exception 'المستحق ملغى'; end if;
  if coalesce(p_kind, '') not in ('payment','deposit','refund') then raise exception 'نوع غير صالح'; end if;
  -- money going back out lowers what was received: owner or payments.correct only
  if p_kind = 'refund' and not ledger_can(c.teacher_id, c.institute_id, 'payments.correct') then
    raise exception 'الاسترداد لصاحب العمل أو لمن يملك صلاحية التصحيح';
  end if;
  if coalesce(p_method, '') not in ('cash','bit','paybox','bank_transfer','cheque','other') then raise exception 'طريقة الدفع غير صالحة'; end if;
  if v_amt <= 0 then raise exception 'المبلغ يجب أن يكون أكبر من صفر'; end if;
  if v_on > (now() at time zone 'Asia/Jerusalem')::date + 1 then raise exception 'تاريخ الدفع في المستقبل'; end if;
  if v_on < (now() at time zone 'Asia/Jerusalem')::date - 366 then raise exception 'تاريخ الدفع قديم جداً'; end if;
  if ledger_looks_like_card(p_note) then raise exception 'لا تكتب أرقام بطاقات أو حسابات بنكية في Classi'; end if;
  v_paid := ledger_paid(c.id);
  if p_kind = 'refund' and v_amt > v_paid then raise exception 'المبلغ المسترد أكبر من المدفوع'; end if;
  if p_kind in ('payment','deposit') and v_paid + v_amt > c.amount
     and not (coalesce(p_allow_over, false) and length(trim(coalesce(p_note, ''))) >= 3) then
    raise exception 'المبلغ أكبر من المتبقي (%). للتسجيل رغم ذلك أضف ملاحظة توضح السبب.', c.amount - v_paid;
  end if;
  insert into payments (charge_id, kind, amount, method, paid_on, note, recorded_by, recorded_by_name)
  values (c.id, p_kind, v_amt, p_method, v_on, nullif(trim(p_note), ''), auth.uid(),
          (select full_name from profiles where id = auth.uid()))
  returning id into v_id;
  perform ledger_audit(c.teacher_id, c.institute_id, 'payment_' || p_kind, 'payment', v_id,
    jsonb_build_object('paid', v_paid), jsonb_build_object('paid', ledger_paid(c.id), 'amount', v_amt, 'method', p_method), p_note);
  return v_id;
end $$;

-- Correction: a void entry that cancels one earlier payment/deposit/refund, with a reason. Owner or payments.correct;
-- the person who recorded it may void their own entry within 24 hours.
create or replace function public.void_payment(p_payment uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare p payments%rowtype; c charges%rowtype; v_id uuid; v_before numeric;
begin
  select * into p from payments where id = p_payment;
  if not found then raise exception 'الدفعة غير موجودة'; end if;
  select * into c from charges where id = p.charge_id for update;
  if not (ledger_can(c.teacher_id, c.institute_id, 'payments.correct')
          or (p.recorded_by = auth.uid() and p.recorded_at > now() - interval '24 hours'
              and ledger_can(c.teacher_id, c.institute_id, 'payments.record'))) then
    raise exception 'ليست لديك صلاحية تصحيح هذه الدفعة';
  end if;
  if p.kind = 'void' then raise exception 'لا يمكن إلغاء تصحيح. سجّل دفعة جديدة.'; end if;
  if exists (select 1 from payments where voids = p.id) then raise exception 'هذه الدفعة مُلغاة سابقاً'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'اكتب سبب التصحيح'; end if;
  if ledger_looks_like_card(p_reason) then raise exception 'لا تكتب أرقام بطاقات أو حسابات بنكية في Classi'; end if;
  v_before := ledger_paid(c.id);
  insert into payments (charge_id, kind, amount, voids, note, recorded_by, recorded_by_name)
  values (c.id, 'void', p.amount, p.id, trim(p_reason), auth.uid(), (select full_name from profiles where id = auth.uid()))
  returning id into v_id;
  perform ledger_audit(c.teacher_id, c.institute_id, 'payment_void', 'payment', p.id,
    jsonb_build_object('paid', v_before, 'kind', p.kind, 'amount', p.amount), jsonb_build_object('paid', ledger_paid(c.id)), p_reason);
  return v_id;
end $$;

-- Change the amount owed or the due date. A reason is required once money has been recorded.
create or replace function public.adjust_charge(p_charge uuid, p_amount numeric, p_due_on date, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c charges%rowtype; v_amt numeric := round(coalesce(p_amount, 0), 2);
begin
  select * into c from charges where id = p_charge for update;
  if not found or not ledger_can(c.teacher_id, c.institute_id, 'payments.correct') then raise exception 'المستحق غير موجود'; end if;
  if c.cancelled_at is not null then raise exception 'المستحق ملغى'; end if;
  if v_amt <= 0 then raise exception 'المبلغ يجب أن يكون أكبر من صفر'; end if;
  if c.deposit_amount is not null and c.deposit_amount > v_amt then raise exception 'المبلغ أقل من العربون المطلوب'; end if;
  if exists (select 1 from payments where charge_id = c.id) and length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'اكتب سبب التعديل';
  end if;
  update charges set amount = v_amt, due_on = p_due_on where id = c.id;
  perform ledger_audit(c.teacher_id, c.institute_id, 'charge_adjust', 'charge', c.id,
    jsonb_build_object('amount', c.amount, 'due_on', c.due_on), jsonb_build_object('amount', v_amt, 'due_on', p_due_on), p_reason);
end $$;

create or replace function public.cancel_charge(p_charge uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c charges%rowtype;
begin
  select * into c from charges where id = p_charge for update;
  if not found or not ledger_can(c.teacher_id, c.institute_id, 'payments.correct') then raise exception 'المستحق غير موجود'; end if;
  if c.cancelled_at is not null then raise exception 'المستحق ملغى سابقاً'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'اكتب سبب الإلغاء'; end if;
  update charges set cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = trim(p_reason) where id = c.id;
  perform ledger_audit(c.teacher_id, c.institute_id, 'charge_cancel', 'charge', c.id,
    jsonb_build_object('paid', ledger_paid(c.id)), null, p_reason);
end $$;

-- Owner only: what an institute's staff may do.
create or replace function public.set_staff_permission(p_institute uuid, p_teacher uuid, p_permission text, p_on boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not ledger_is_owner(null, p_institute) then raise exception 'هذه الصلاحية لصاحب المعهد فقط'; end if;
  if p_permission not in ('payments.record','payments.correct','payments.reports') then raise exception 'صلاحية غير معروفة'; end if;
  if not exists (select 1 from institute_teachers where institute_id = p_institute and teacher_id = p_teacher and status = 'accepted') then
    raise exception 'المعلم ليس من طاقم المعهد';
  end if;
  if p_on then
    insert into staff_permissions (institute_id, teacher_id, permission, granted_by) values (p_institute, p_teacher, p_permission, auth.uid())
    on conflict do nothing;
  else
    delete from staff_permissions where institute_id = p_institute and teacher_id = p_teacher and permission = p_permission;
  end if;
  perform ledger_audit(null, p_institute, case when p_on then 'permission_grant' else 'permission_revoke' end, 'staff', p_teacher,
    null, jsonb_build_object('permission', p_permission), null);
end $$;

-- ================= reads =================
-- The business's charges with computed totals. p_status filters (null = all). Staff with payments.record see them too.
create or replace function public.business_charges(p_teacher uuid default null, p_institute uuid default null, p_status text default null)
returns table (id uuid, customer_label text, customer_id uuid, description text, source_kind text, source_id uuid,
               amount numeric, deposit_amount numeric, paid numeric, remaining numeric, status text, due_on date,
               created_at timestamptz, cancel_reason text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_t uuid := p_teacher; v_i uuid := p_institute;
begin
  if v_t is null and v_i is null then select b.teacher_id, b.institute_id into v_t, v_i from ledger_my_business() b; end if;
  if (v_t is null and v_i is null) or not ledger_can(v_t, v_i, 'payments.record') then return; end if;
  return query
  select c.id, c.customer_label, c.customer_id, c.description, c.source_kind, c.source_id, c.amount, c.deposit_amount,
         ledger_paid(c.id), greatest(c.amount - ledger_paid(c.id), 0), ledger_status(c.id), c.due_on, c.created_at, c.cancel_reason
    from charges c
   where ((v_t is not null and c.teacher_id = v_t) or (v_i is not null and c.institute_id = v_i))
     and (p_status is null or ledger_status(c.id) = p_status)
   order by case ledger_status(c.id) when 'overdue' then 0 when 'partial' then 1 when 'unpaid' then 2 when 'paid' then 3 else 4 end,
            c.due_on nulls last, c.created_at desc;
end $$;

-- Every entry of one charge, oldest first, with whether it was voided (business view).
create or replace function public.charge_entries(p_charge uuid)
returns table (id uuid, kind text, amount numeric, method text, paid_on date, note text, voids uuid, voided boolean,
               recorded_by_name text, recorded_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c charges%rowtype;
begin
  select * into c from charges where charges.id = p_charge;
  if not found or not ledger_can(c.teacher_id, c.institute_id, 'payments.record') then return; end if;
  return query
  select p.id, p.kind, p.amount, p.method, p.paid_on, p.note, p.voids,
         exists (select 1 from payments v where v.voids = p.id), p.recorded_by_name, p.recorded_at
    from payments p where p.charge_id = p_charge order by p.recorded_at, p.id;
end $$;

-- The customer's own charges (read only), with the business name. The app shows them with the fixed notice that the
-- status was recorded by the business and is not confirmed by Classi.
create or replace function public.my_charges()
returns table (id uuid, business_name text, description text, amount numeric, paid numeric, remaining numeric,
               status text, due_on date, created_at timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select c.id, coalesce(t.name, i.name), c.description, c.amount, ledger_paid(c.id), greatest(c.amount - ledger_paid(c.id), 0),
         ledger_status(c.id), c.due_on, c.created_at
    from charges c left join teachers t on t.id = c.teacher_id left join institutes i on i.id = c.institute_id
   where auth.uid() is not null and c.customer_id = auth.uid()
   order by c.created_at desc
$$;

-- Report for a period: received by method (payments − refunds, by paid_on), and what is open now with overdue ageing.
create or replace function public.ledger_report(p_from date, p_to date, p_teacher uuid default null, p_institute uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_t uuid := p_teacher; v_i uuid := p_institute; v_today date := (now() at time zone 'Asia/Jerusalem')::date; r jsonb;
begin
  if v_t is null and v_i is null then select b.teacher_id, b.institute_id into v_t, v_i from ledger_my_business() b; end if;
  if (v_t is null and v_i is null) or not (ledger_is_owner(v_t, v_i) or ledger_staff_can(v_i, 'payments.reports')) then
    raise exception 'ليست لديك صلاحية التقارير';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then raise exception 'فترة غير صالحة'; end if;
  with mine as (
    select c.* from charges c where (v_t is not null and c.teacher_id = v_t) or (v_i is not null and c.institute_id = v_i)
  ), live as (
    select p.* from payments p join mine m on m.id = p.charge_id
     where p.kind in ('payment','deposit','refund') and not exists (select 1 from payments v where v.voids = p.id)
  ), received as (
    select method, sum(case when kind = 'refund' then -amount else amount end) total
      from live where paid_on between p_from and p_to group by method
  ), open_ as (
    select m.id, m.due_on, greatest(m.amount - ledger_paid(m.id), 0) rest from mine m
     where m.cancelled_at is null and ledger_paid(m.id) < m.amount
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'received_total', coalesce((select sum(total) from received), 0),
    'received_by_method', coalesce((select jsonb_object_agg(method, total) from received), '{}'::jsonb),
    'charged_in_period', coalesce((select sum(amount) from mine where cancelled_at is null and created_at::date between p_from and p_to), 0),
    'open_total', coalesce((select sum(rest) from open_), 0),
    'open_count', (select count(*) from open_),
    'overdue_0_30', coalesce((select sum(rest) from open_ where due_on < v_today and due_on >= v_today - 30), 0),
    'overdue_31_60', coalesce((select sum(rest) from open_ where due_on < v_today - 30 and due_on >= v_today - 60), 0),
    'overdue_over_60', coalesce((select sum(rest) from open_ where due_on < v_today - 60), 0),
    'corrections', (select count(*) from payments p join mine m on m.id = p.charge_id where p.kind = 'void' and p.recorded_at::date between p_from and p_to),
    'notice', 'سجل إداري لما سجّله صاحب العمل. Classi لا يستلم الأموال ولا يؤكد وصولها، وهذا ليس مستنداً ضريبياً.'
  ) into r;
  return r;
end $$;

-- The business's own audit trail (owner only).
create or replace function public.business_audit(p_limit int default 100, p_teacher uuid default null, p_institute uuid default null)
returns table (at timestamptz, actor_name text, action text, entity text, entity_id uuid, before jsonb, after jsonb, reason text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_t uuid := p_teacher; v_i uuid := p_institute;
begin
  if v_t is null and v_i is null then select b.teacher_id, b.institute_id into v_t, v_i from ledger_my_business() b; end if;
  if (v_t is null and v_i is null) or not ledger_is_owner(v_t, v_i) then return; end if;
  return query
  select a.at, p.full_name, a.action, a.entity, a.entity_id, a.before, a.after, a.reason
    from audit_log a left join profiles p on p.id = a.actor
   where (v_t is not null and a.teacher_id = v_t) or (v_i is not null and a.institute_id = v_i)
   order by a.at desc, a.id desc limit least(greatest(coalesce(p_limit, 100), 1), 500);
end $$;

-- The businesses whose ledger the caller may open, with what they may do there.
create or replace function public.my_ledger_businesses()
returns table (kind text, business_id uuid, name text, is_owner boolean, can_record boolean, can_correct boolean, can_reports boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select 'teacher', t.id, t.name, true, true, true, true from teachers t where auth.uid() is not null and t.user_id = auth.uid()
  union all
  select 'institute', i.id, i.name, true, true, true, true from institutes i where auth.uid() is not null and i.owner_id = auth.uid()
  union all
  select 'institute', i.id, i.name, false, ledger_staff_can(i.id, 'payments.record'), ledger_staff_can(i.id, 'payments.correct'),
         ledger_staff_can(i.id, 'payments.reports')
    from institutes i
   where auth.uid() is not null and coalesce(i.owner_id, '00000000-0000-0000-0000-000000000000') <> auth.uid()
     and exists (select 1 from staff_permissions sp join teachers t on t.id = sp.teacher_id and t.user_id = auth.uid()
                  join institute_teachers it on it.institute_id = sp.institute_id and it.teacher_id = sp.teacher_id and it.status = 'accepted'
                  where sp.institute_id = i.id)
$$;

-- Owner of an institute: its accepted staff and the ledger permissions each holds.
create or replace function public.institute_staff_permissions(p_institute uuid)
returns table (teacher_id uuid, name text, permissions text[])
language sql stable security definer set search_path = public, pg_temp as $$
  select t.id, t.name, coalesce(array_agg(sp.permission order by sp.permission) filter (where sp.permission is not null), '{}')
    from institute_teachers it join teachers t on t.id = it.teacher_id
    left join staff_permissions sp on sp.institute_id = it.institute_id and sp.teacher_id = it.teacher_id
   where it.institute_id = p_institute and it.status = 'accepted' and ledger_is_owner(null, p_institute)
   group by t.id, t.name order by t.name
$$;

revoke all on function public.my_ledger_businesses(), public.institute_staff_permissions(uuid) from public, anon;
grant execute on function public.my_ledger_businesses(), public.institute_staff_permissions(uuid) to authenticated;

revoke all on function public.create_charge(uuid, uuid, text, text, numeric, date, numeric, uuid), public.charge_for_booking(uuid, date),
  public.record_payment(uuid, text, numeric, text, date, text, boolean), public.void_payment(uuid, text),
  public.adjust_charge(uuid, numeric, date, text), public.cancel_charge(uuid, text),
  public.set_staff_permission(uuid, uuid, text, boolean), public.business_charges(uuid, uuid, text), public.charge_entries(uuid),
  public.my_charges(), public.ledger_report(date, date, uuid, uuid), public.business_audit(int, uuid, uuid) from public, anon;
grant execute on function public.create_charge(uuid, uuid, text, text, numeric, date, numeric, uuid), public.charge_for_booking(uuid, date),
  public.record_payment(uuid, text, numeric, text, date, text, boolean), public.void_payment(uuid, text),
  public.adjust_charge(uuid, numeric, date, text), public.cancel_charge(uuid, text),
  public.set_staff_permission(uuid, uuid, text, boolean), public.business_charges(uuid, uuid, text), public.charge_entries(uuid),
  public.my_charges(), public.ledger_report(date, date, uuid, uuid), public.business_audit(int, uuid, uuid) to authenticated;
