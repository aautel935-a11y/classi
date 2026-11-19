-- v3 customer payments ledger (charges, append-only payments, corrections, audit, staff permissions, reports).
-- Every check prints PASS:/FAIL:. Synthetic accounts only (ids 7100…). Run: sh supabase/tests/run.sh ledger_test
\pset pager off
\pset footer off
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
 ('71000000-0000-0000-0000-00000000000a','samer@t','{"full_name":"سامر مصاروة"}'),
 ('71000000-0000-0000-0000-00000000000b','owner@t','{"full_name":"صاحب معهد المستقبل"}'),
 ('71000000-0000-0000-0000-00000000000c','staff@t','{"full_name":"موظف المعهد"}'),
 ('71000000-0000-0000-0000-00000000000d','mom@t','{"full_name":"أم يوسف"}'),
 ('71000000-0000-0000-0000-00000000000e','other@t','{"full_name":"معلم آخر"}'),
 ('71000000-0000-0000-0000-00000000000f','owner2@t','{"full_name":"صاحب معهد آخر"}');
update teachers set user_id='71000000-0000-0000-0000-00000000000a' where name='سامر مصاروة';
update teachers set user_id='71000000-0000-0000-0000-00000000000e' where name='نور كبها';
update institutes set owner_id='71000000-0000-0000-0000-00000000000b' where name='معهد المستقبل';
update institutes set owner_id='71000000-0000-0000-0000-00000000000f' where id = (select id from institutes where name <> 'معهد المستقبل' order by name limit 1);
-- the institute's staff member: a teacher linked to it (accepted), not its owner and not Samer/Noor
create temp table staffer as
  select it.teacher_id id from institute_teachers it join institutes i on i.id = it.institute_id
    join teachers t on t.id = it.teacher_id
   where i.name = 'معهد المستقبل' and it.status = 'accepted' and t.user_id is null limit 1;
update teachers set user_id='71000000-0000-0000-0000-00000000000c' where id = (select id from staffer);
create temp table ids as select
  (select id from teachers where name='سامر مصاروة') samer,
  (select id from institutes where name='معهد المستقبل') inst,
  (select id from institutes where owner_id='71000000-0000-0000-0000-00000000000f') inst2,
  (select id from staffer) staff_t;
grant select on ids to authenticated;
-- mom is a real customer of Samer (one confirmed booking): only then may Samer link charges to her account
insert into bookings (offering_id, booked_by, starts_at, status, price)
select o.id, '71000000-0000-0000-0000-00000000000d', now() + interval '3 days', 'confirmed', 180
  from offerings o where o.teacher_id = (select samer from ids) limit 1;
create temp table v (k text primary key, id uuid);
grant all on v to authenticated;
\echo '===== preconditions'
select t_is('a staff teacher exists', $$select (staff_t is not null)::text from ids$$, 'true');
select t_is('second institute exists', $$select (inst2 is not null and inst2 <> inst)::text from ids$$, 'true');

\echo '===== no direct table access'
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000a';
select t_err('authenticated cannot read charges', $$select count(*) from charges$$);
select t_err('authenticated cannot insert payments', $$insert into payments (charge_id, kind, amount, method, paid_on) values (gen_random_uuid(), 'payment', 1, 'cash', current_date)$$);
select t_err('authenticated cannot read audit_log', $$select count(*) from audit_log$$);
select t_err('internal helper not callable', $$select ledger_paid(gen_random_uuid())$$);
reset role;
set role anon; set request.jwt.claim.sub='';
select t_err('anon cannot create a charge', $$select create_charge(null, null, 'x', 'y', 10)$$);
select t_err('anon cannot list charges', $$select * from business_charges()$$);
reset role;

\echo '===== teacher: charge, deposit, partial, paid'
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000a';
select t_ok('create charge 500 with deposit 100, customer mom',
  $$insert into v select 'c1', create_charge(null, null, 'أم يوسف', 'رزمة 5 حصص', 500, current_date + 10, 100, '71000000-0000-0000-0000-00000000000d')$$);
select t_is('new charge is unpaid', $$select status from business_charges() where id = (select id from v where k='c1')$$, 'unpaid');
select t_ok('deposit 100 by Bit', $$insert into v select 'p1', record_payment((select id from v where k='c1'), 'deposit', 100, 'bit')$$);
select t_is('after deposit: partial', $$select status from business_charges() where id = (select id from v where k='c1')$$, 'partial');
select t_is('paid 100 remaining 400', $$select paid::int || '/' || remaining::int from business_charges() where id = (select id from v where k='c1')$$, '100/400');
select t_ok('cash 150.50', $$insert into v select 'p2', record_payment((select id from v where k='c1'), 'payment', 150.50, 'cash', current_date, 'دفعة ثانية')$$);
select t_err('over-payment refused without a note', $$select record_payment((select id from v where k='c1'), 'payment', 300, 'cash')$$);
select t_ok('transfer 249.50 completes it', $$insert into v select 'p3', record_payment((select id from v where k='c1'), 'payment', 249.50, 'bank_transfer')$$);
select t_is('paid', $$select status || ':' || remaining from business_charges() where id = (select id from v where k='c1')$$, 'paid:0.00');
select t_err('bad method refused', $$select record_payment((select id from v where k='c1'), 'payment', 1, 'crypto')$$);
select t_err('zero amount refused', $$select record_payment((select id from v where k='c1'), 'payment', 0, 'cash')$$);
select t_err('future date refused', $$select record_payment((select id from v where k='c1'), 'payment', 1, 'cash', current_date + 5)$$);
select t_err('card number in a note refused', $$select record_payment((select id from v where k='c1'), 'refund', 1, 'cash', current_date, 'card 4111 1111 1111 1111')$$);
select t_ok('a phone number in a note is fine', $$select record_payment((select id from v where k='c1'), 'refund', 1, 'cash', current_date, 'اتصل 0501234567')$$);
select t_is('refund 1 reopens 1', $$select status || ':' || remaining from business_charges() where id = (select id from v where k='c1')$$, 'partial:1.00');
select t_err('refund more than paid refused', $$select record_payment((select id from v where k='c1'), 'refund', 10000, 'cash')$$);

\echo '===== corrections, never silent'
select t_err('void without a reason refused', $$select void_payment((select id from v where k='p2'), '')$$);
select t_ok('void the cash entry with a reason', $$select void_payment((select id from v where k='p2'), 'سُجّلت مرتين بالخطأ')$$);
select t_is('voided entry no longer counts', $$select paid::text from business_charges() where id = (select id from v where k='c1')$$, '348.50');
select t_err('void twice refused', $$select void_payment((select id from v where k='p2'), 'مرة أخرى')$$);
select t_is('entries keep the original and the void', $$select count(*)::text from charge_entries((select id from v where k='c1')) where voided or kind = 'void'$$, '2');
select t_err('void of a void refused', $$select void_payment((select id from charge_entries((select id from v where k='c1')) where kind='void'), 'xyz')$$);
select t_err('adjust after payments needs a reason', $$select adjust_charge((select id from v where k='c1'), 600, null, '')$$);
select t_ok('adjust with a reason', $$select adjust_charge((select id from v where k='c1'), 400, current_date + 10, 'خصم متفق عليه')$$);
select t_err('adjust below the deposit refused', $$select adjust_charge((select id from v where k='c1'), 50, null, 'تجربة')$$);
reset role;
\echo '===== append-only, even for the table owner'
select t_err('UPDATE payments refused for postgres', $$update payments set amount = 1 where id = (select id from v where k='p1')$$);
select t_err('DELETE payments refused for postgres', $$delete from payments where id = (select id from v where k='p1')$$);
select t_err('DELETE audit_log refused for postgres', $$delete from audit_log$$);
select t_is('audit rows for the teacher', $$select (count(*) >= 7)::text from audit_log where teacher_id = (select samer from ids)$$, 'true');
select t_is('void recorded with its reason', $$select reason from audit_log where action = 'payment_void'$$, 'سُجّلت مرتين بالخطأ');

\echo '===== overdue and cancel'
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000a';
select t_ok('charge due yesterday', $$insert into v select 'c2', create_charge(null, null, 'زبون نقدي', 'حصة', 120, current_date - 1)$$);
select t_is('overdue', $$select status from business_charges() where id = (select id from v where k='c2')$$, 'overdue');
select t_ok('partial on overdue', $$select record_payment((select id from v where k='c2'), 'payment', 20, 'cash')$$);
select t_is('still overdue while money remains', $$select status from business_charges() where id = (select id from v where k='c2')$$, 'overdue');
select t_is('overdue filter', $$select count(*)::text from business_charges(null, null, 'overdue')$$, '1');
select t_err('cancel needs a reason', $$select cancel_charge((select id from v where k='c2'), '')$$);
select t_ok('cancel', $$select cancel_charge((select id from v where k='c2'), 'اتفقنا على الإلغاء')$$);
select t_is('cancelled', $$select status from business_charges() where id = (select id from v where k='c2')$$, 'cancelled');
select t_err('no payments on a cancelled charge', $$select record_payment((select id from v where k='c2'), 'payment', 1, 'cash')$$);
select t_is('report: received this month', $$select ((ledger_report(current_date - 30, current_date))->>'received_total')$$, '368.50');
select t_is('report: open total excludes cancelled', $$select ((ledger_report(current_date - 30, current_date))->>'open_total')$$, '51.50');
select t_is('report carries the notice', $$select (ledger_report(current_date - 30, current_date) ? 'notice')::text$$, 'true');
select t_err('report period too long refused', $$select ledger_report(current_date - 900, current_date)$$);
select t_is('owner audit trail visible', $$select (count(*) > 0)::text from business_audit()$$, 'true');
reset role;

\echo '===== isolation: another teacher, another institute, the customer'
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000e';
select t_is('other teacher sees none of Samer''s charges', $$select count(*)::text from business_charges((select samer from ids))$$, '0');
select t_is('other teacher sees no entries', $$select count(*)::text from charge_entries((select id from v where k='c1'))$$, '0');
select t_err('other teacher cannot record on Samer''s charge', $$select record_payment((select id from v where k='c1'), 'payment', 1, 'cash')$$);
select t_err('other teacher cannot void', $$select void_payment((select id from v where k='p1'), 'سرقة')$$);
select t_err('other teacher cannot cancel', $$select cancel_charge((select id from v where k='c1'), 'سرقة')$$);
select t_err('other teacher cannot charge on Samer''s behalf', $$select create_charge((select samer from ids), null, 'x', 'y', 10)$$);
select t_err('other teacher cannot read Samer''s report', $$select ledger_report(current_date - 1, current_date, (select samer from ids))$$);
select t_is('other teacher reads no audit of Samer', $$select count(*)::text from business_audit(100, (select samer from ids))$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000d';
select t_is('customer sees her charge, read only', $$select status || ':' || remaining from my_charges()$$, 'partial:51.50');
select t_err('customer cannot record a payment', $$select record_payment((select id from v where k='c1'), 'payment', 51.50, 'cash')$$);
select t_err('customer cannot void', $$select void_payment((select id from v where k='p1'), 'لم أدفع')$$);
select t_is('customer sees no business list', $$select count(*)::text from business_charges((select samer from ids))$$, '0');
select t_err('customer has no business', $$select create_charge(null, null, 'x', 'y', 10)$$);
reset role;

\echo '===== institute: owner, staff permissions, second institute'
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000b';
select t_ok('institute owner creates a charge', $$insert into v select 'c3', create_charge(null, (select inst from ids), 'طالب المعهد', 'دورة', 900, current_date + 30)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000c';
select t_is('staff without permission sees nothing', $$select count(*)::text from business_charges(null, (select inst from ids))$$, '0');
select t_err('staff without permission cannot record', $$select record_payment((select id from v where k='c3'), 'payment', 100, 'cash')$$);
select t_err('staff cannot grant themselves a permission', $$select set_staff_permission((select inst from ids), (select staff_t from ids), 'payments.record', true)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000b';
select t_ok('owner grants payments.record', $$select set_staff_permission((select inst from ids), (select staff_t from ids), 'payments.record', true)$$);
select t_is('owner sees the grant', $$select permissions::text from institute_staff_permissions((select inst from ids)) where teacher_id = (select staff_t from ids)$$, '{payments.record}');
select t_is('owner''s ledger list has the institute as owner', $$select is_owner::text from my_ledger_businesses() where business_id = (select inst from ids)$$, 'true');
select t_err('owner cannot grant to a non-staff teacher', $$select set_staff_permission((select inst from ids), (select samer from ids), 'payments.record', true)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000c';
select t_is('staff with payments.record sees the institute''s charges', $$select count(*)::text from business_charges(null, (select inst from ids))$$, '1');
select t_is('staff''s ledger list: the institute, record only', $$select is_owner::text || can_record::text || can_correct::text || can_reports::text from my_ledger_businesses() where business_id = (select inst from ids)$$, 'falsetruefalsefalse');
select t_ok('staff records a payment', $$insert into v select 'p4', record_payment((select id from v where k='c3'), 'payment', 300, 'paybox')$$);
select t_ok('staff may void own entry within 24h', $$select void_payment((select id from v where k='p4'), 'المبلغ خطأ')$$);
select t_err('staff cannot refund (needs payments.correct)', $$select record_payment((select id from v where k='c3'), 'refund', 10, 'cash')$$);
select t_err('staff cannot put a charge in a stranger''s account', $$select create_charge(null, (select inst from ids), 'غريب', 'دين', 50, null, null, '71000000-0000-0000-0000-00000000000e')$$);
select t_ok('staff records again', $$insert into v select 'p5', record_payment((select id from v where k='c3'), 'payment', 200, 'paybox')$$);
select t_err('staff cannot cancel (needs payments.correct)', $$select cancel_charge((select id from v where k='c3'), 'إلغاء')$$);
select t_err('staff cannot adjust', $$select adjust_charge((select id from v where k='c3'), 10, null, 'خصم')$$);
select t_err('staff cannot read reports without payments.reports', $$select ledger_report(current_date - 1, current_date, null, (select inst from ids))$$);
select t_is('staff reads no audit trail', $$select count(*)::text from business_audit(100, null, (select inst from ids))$$, '0');
reset role;
-- an entry older than 24h: only an owner/corrector may void it
set session_replication_role = replica;
insert into payments (charge_id, kind, amount, method, paid_on, recorded_by, recorded_at)
values ((select id from v where k='c3'), 'payment', 50, 'cash', current_date - 3, '71000000-0000-0000-0000-00000000000c', now() - interval '3 days');
set session_replication_role = origin;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000c';
select t_err('staff cannot void own entry after 24h', $$select void_payment((select id from charge_entries((select id from v where k='c3')) where amount = 50), 'متأخر')$$);
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000b';
select t_ok('owner revokes the permission', $$select set_staff_permission((select inst from ids), (select staff_t from ids), 'payments.record', false)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000c';
select t_is('after revoke: staff sees nothing', $$select count(*)::text from business_charges(null, (select inst from ids))$$, '0');
select t_is('after revoke: the institute leaves the staff''s ledger list', $$select count(*)::text from my_ledger_businesses() where business_id = (select inst from ids)$$, '0');
select t_is('staff cannot list the institute''s permissions', $$select count(*)::text from institute_staff_permissions((select inst from ids))$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000f';
select t_is('second institute owner sees none of the first', $$select count(*)::text from business_charges(null, (select inst from ids))$$, '0');
select t_err('second institute owner cannot record', $$select record_payment((select id from v where k='c3'), 'payment', 1, 'cash')$$);
select t_err('second institute owner cannot grant on the first', $$select set_staff_permission((select inst from ids), (select staff_t from ids), 'payments.record', true)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000a';
select t_is('teacher does not see the institute''s charges', $$select count(*)::text from business_charges(null, (select inst from ids))$$, '0');
reset role;

\echo '===== charge from a booking'
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000a';
select t_ok('charge for the booking', $$insert into v select 'c4', charge_for_booking((select b.id from bookings b join offerings o on o.id=b.offering_id where o.teacher_id=(select samer from ids) and b.booked_by='71000000-0000-0000-0000-00000000000d' and b.price=180))$$);
select t_is('same booking returns the same charge', $$select (charge_for_booking((select b.id from bookings b join offerings o on o.id=b.offering_id where o.teacher_id=(select samer from ids) and b.booked_by='71000000-0000-0000-0000-00000000000d' and b.price=180)) = (select id from v where k='c4'))::text$$, 'true');
select t_is('booking charge: amount and customer', $$select amount::int || ':' || (customer_id = '71000000-0000-0000-0000-00000000000d')::text from business_charges() where id = (select id from v where k='c4')$$, '180:true');
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000e';
select t_err('another teacher cannot charge Samer''s booking', $$select charge_for_booking((select b.id from bookings b join offerings o on o.id=b.offering_id where o.teacher_id=(select samer from ids) and b.price=180))$$);
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000a';
select t_err('teacher cannot put a charge in the account of someone who never booked', $$select create_charge(null, null, 'x', 'y', 10, null, null, '71000000-0000-0000-0000-00000000000b')$$);
select t_ok('teacher may link a real customer (she booked)', $$select create_charge(null, null, 'أم يوسف', 'حصة إضافية', 60, null, null, '71000000-0000-0000-0000-00000000000d')$$);
reset role;
set role authenticated; set request.jwt.claim.sub='71000000-0000-0000-0000-00000000000d';
select t_is('customer now sees three charges', $$select count(*)::text from my_charges()$$, '3');
reset role;
