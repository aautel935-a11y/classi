-- Rollback of 20261120000000_v3_ledger.sql. Removes the ledger completely: charges, payments, audit_log and staff
-- permissions ARE DELETED. Only for a rollback before real businesses use it; afterwards export them first.
-- Run the business-access rollback first if it was applied (it writes to audit_log).
begin;
drop function if exists public.institute_staff_permissions(uuid);
drop function if exists public.my_ledger_businesses();
drop function if exists public.business_audit(int, uuid, uuid);
drop function if exists public.ledger_report(date, date, uuid, uuid);
drop function if exists public.my_charges();
drop function if exists public.charge_entries(uuid);
drop function if exists public.business_charges(uuid, uuid, text);
drop function if exists public.set_staff_permission(uuid, uuid, text, boolean);
drop function if exists public.cancel_charge(uuid, text);
drop function if exists public.adjust_charge(uuid, numeric, date, text);
drop function if exists public.void_payment(uuid, text);
drop function if exists public.record_payment(uuid, text, numeric, text, date, text, boolean);
drop function if exists public.charge_for_booking(uuid, date);
drop function if exists public.create_charge(uuid, uuid, text, text, numeric, date, numeric, uuid);
drop function if exists public.ledger_status(uuid);
drop function if exists public.ledger_paid(uuid);
drop function if exists public.ledger_audit(uuid, uuid, text, text, uuid, jsonb, jsonb, text);
drop function if exists public.ledger_looks_like_card(text);
drop function if exists public.ledger_my_business();
drop function if exists public.ledger_can(uuid, uuid, text);
drop function if exists public.ledger_staff_can(uuid, text);
drop function if exists public.ledger_is_owner(uuid, uuid);
drop table if exists public.staff_permissions;
drop table if exists public.payments;     -- the append-only trigger fires on row DELETE, not on DROP TABLE
drop table if exists public.charges;
drop table if exists public.audit_log;
drop function if exists public.ledger_append_only();
commit;
