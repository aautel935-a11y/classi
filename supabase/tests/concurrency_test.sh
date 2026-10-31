#!/bin/sh
# Concurrency checks with two real database connections at the same time (SEC-21, SEC-22, double booking).
# Prints PASS:/FAIL: lines and exits non-zero on any FAIL. Synthetic data only.
T="$(cd "$(dirname "$0")" && pwd)"
DB=ct_concurrency
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q -At -d $DB"
DB=$DB sh "$T/run.sh" today_test >/dev/null 2>&1 || { echo "FAIL: could not build the test database"; exit 1; }

$P >/dev/null <<'SQL'
insert into auth.users (id, email, raw_user_meta_data) values
 ('70000000-0000-0000-0000-000000000001','a@t','{"full_name":"أ"}'),
 ('70000000-0000-0000-0000-000000000002','b@t','{"full_name":"ب"}'),
 ('70000000-0000-0000-0000-000000000003','owner@t','{"full_name":"صاحب"}');
update institutes set owner_id='70000000-0000-0000-0000-000000000003' where name='معهد المستقبل';
-- an institute's private lessons (no teacher row: the case SEC-22 was about)
insert into offerings (type, institute_id, title, places, price, minutes, active, review_status)
select 'private', id, 'خصوصي في المعهد', array['center']::place_kind[], 100, 60, true, 'approved' from institutes where name='معهد المستقبل';
-- a course booking at installment 2 of 3
insert into bookings (offering_id, booked_by, minutes, status, pay_method, installments_total, installments_paid)
select id, '70000000-0000-0000-0000-000000000001', 90, 'confirmed', 'installments', 3, 2 from offerings where title='إنجليزي محادثة للإعدادي';
SQL

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1 = $2"; pass=$((pass+1)); else echo "FAIL: $1 -> got $2, expected $3"; fail=$((fail+1)); fi; }

# SEC-21: two staff taps on "received" for the last installment at the same moment.
B=$($P -c "select id from bookings where installments_total = 3 limit 1")
for i in 1 2; do
  ( $P -c "begin; set local role authenticated; set local request.jwt.claim.sub='70000000-0000-0000-0000-000000000003';
           select confirm_payment('$B'); select pg_sleep(1); commit;" >/dev/null 2>&1 ) &
done
wait
check "installments after two simultaneous confirmations" "$($P -c "select installments_paid || '/' || installments_total from bookings where id='$B'")" "3/3"

# SEC-22: two students book the same institute private slot at the same moment.
O=$($P -c "select id from offerings where title='خصوصي في المعهد'")
AT=$($P -c "select (test_day(1) + time '17:00') at time zone 'Asia/Jerusalem'")
for u in 1 2; do
  ( $P -c "begin; set local role authenticated; set local request.jwt.claim.sub='70000000-0000-0000-0000-00000000000$u';
           select create_booking('$O', null, '$AT', null, 'cash', false, 'center'); select pg_sleep(1); commit;" >/dev/null 2>&1 ) &
done
wait
check "bookings on one institute slot after two simultaneous requests" "$($P -c "select count(*) from bookings where offering_id='$O' and status in ('pending','confirmed')")" "1"

# Teacher double booking (already protected; kept as a regression check).
O2=$($P -c "select id from offerings where title='رياضيات بجروت 5 وحدات'")
AT2=$($P -c "select (test_day(2) + time '16:00') at time zone 'Asia/Jerusalem'")
for u in 1 2; do
  ( $P -c "begin; set local role authenticated; set local request.jwt.claim.sub='70000000-0000-0000-0000-00000000000$u';
           select create_booking('$O2', null, '$AT2', null, 'cash', false, 'online'); select pg_sleep(1); commit;" >/dev/null 2>&1 ) &
done
wait
check "bookings on one teacher slot after two simultaneous requests" "$($P -c "select count(*) from bookings where offering_id='$O2' and starts_at='$AT2' and status in ('pending','confirmed')")" "1"

psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q -c "drop database if exists $DB" >/dev/null
echo "concurrency: $pass passed, $fail failed"
[ $fail = 0 ]
