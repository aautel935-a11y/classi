#!/bin/sh
# Tests ALL guarded production files (supabase/production: step 0 + the 12 migrations, rollbacks, the step-10 gate) on a
# throwaway LOCAL database with production's schema (main's 25 migrations). The files only run on production's
# cluster id: the test runs copies in which that one constant is replaced by this server's, and checks nothing else
# differs. Never connects to a hosted database. Every check prints PASS: or FAIL:.
# Usage: sh supabase/tests/production_files_test.sh
set -u
T="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$T/../.." && pwd)"
PROD_ID=7692130048193495360; LAST=20261027020000
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
DB=ct_pf; SRC="$REPO/supabase/production"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
ko() { echo "FAIL: $1"; fail=$((fail + 1)); }
q() { $P -d "$DB" -Atc "$1" 2>/dev/null; }
state() { echo "$(q "select count(*) || ':' || max(version) from supabase_migrations.schema_migrations")#$(q "select coalesce(string_agg(key || '=' || left(value, 12), ',' order by key), '') from public.app_secrets")#$($P -d "$DB" -At -f "$REPO/scripts/production/fingerprint.sql" | grep '|' | tr '\n' ';')"; }
run() { $P -d "$DB" -v ON_ERROR_STOP=1 -f "$W/f/$1" > "$W/out" 2>&1; }
DIFF="${PRODFILES_DIFF:-/tmp/prodfiles_diff.log}"; : > "$DIFF"
applies() {
  if run "$1"; then ok "$2"; return; fi
  ko "$2: $(grep -m1 ERROR "$W/out")"
  if [ ! -s "$DIFF" ]; then   # first failure only: what the file expected vs what this server has (no data, structure only)
    { echo "first failure: $1"; echo "-- expected (first guard of the file):"
      awk '/\$exp\$/{f=1} f{print} /\$exp\$ then/{exit}' "$W/f/$1" | sed 's/.*\$exp\$//; s/\$exp\$ then.*//' | grep '|'
      echo "-- this server:"; $P -d "$DB" -At -f "$REPO/scripts/production/fingerprint.sql" | grep '|'
      echo "-- server: $($P -Atc 'show server_version')"
      echo "-- psql output of the failing file:"; grep -v "^NOTICE\|^psql:.*NOTICE" "$W/out" | cut -c1-200 | tail -25; } > "$DIFF"
  fi
}
refused() { # $1 file, $2 expected text, $3 label
  b0=$(state)
  if run "$1"; then ko "$3: it ran"
  elif grep -q "$2" "$W/out" && [ "$(state)" = "$b0" ]; then ok "$3 (refused, nothing changed)"
  else ko "$3: $(grep -m1 ERROR "$W/out")"; fi
}
file() { ls "$SRC" | grep "^$1_$2_" | head -1; }   # file apply 05 -> apply_05_...

# 1. the files: only the cluster id differs in the copies; the committed files are the generators' output
mkdir "$W/f"; LOCAL_ID=$($P -At -c "select system_identifier from pg_control_system()")
for f in "$SRC"/*.sql; do sed "s/$PROD_ID/$LOCAL_ID/g" "$f" > "$W/f/$(basename "$f")"; done
n=$(ls "$SRC"/*.sql | wc -l); other=0
for f in "$SRC"/*.sql; do d=$(diff "$f" "$W/f/$(basename "$f")" | grep '^<' | grep -vc "$PROD_ID"); [ "$d" = 0 ] || other=1; done
[ "$other" = 0 ] && [ "$n" = 27 ] && ok "27 production files; the test copies differ only in the cluster id" || ko "files: $n, other differences: $other"
if [ "${SKIP_REGEN:-0}" != 1 ]; then
  python3 "$REPO/scripts/production/gen_bootstrap.py" > /dev/null && python3 "$REPO/scripts/production/gen_production_files.py" > /dev/null \
    && git -C "$REPO" diff --quiet -- supabase/production && [ -z "$(git -C "$REPO" ls-files --others --exclude-standard -- supabase/production)" ] \
    && ok "the committed files are exactly the generators' output" || ko "supabase/production differs from the generators' output"
fi

# 2. a production-like database (no tracking, no marker, production's app_secrets keys with synthetic values)
$P -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
D="env PGOPTIONS=-cclient_min_messages=warning $P -d $DB -v ON_ERROR_STOP=1"
$D -f "$T/supabase_stub.sql" >/dev/null
for f in "$REPO"/supabase/migrations/*.sql; do v=$(basename "$f" | cut -d_ -f1); [ "$v" -le "$LAST" ] && $D -f "$f" >/dev/null; done
$D -c "insert into public.app_secrets values ('dispatch_url', 'synthetic'), ('dispatch_secret', 'synthetic'), ('vapid_public', 'synthetic') on conflict do nothing" >/dev/null
[ "$($P -d $DB -At -f "$REPO/scripts/production/fingerprint.sql" | grep '|')" = "$(cat "$REPO/scripts/production/expected_$LAST.txt")" ] && ok "the base is production's recorded schema" || ko "base fingerprint"

# 3. order and identity
refused "$(file apply 01)" "not marked production" "step 1 before step 0"
$P -d "$DB" -v ON_ERROR_STOP=1 -f "$SRC/$(file apply 01)" > "$W/out" 2>&1 && ko "the REAL step-1 file ran on a database that is not production" || { grep -q "not the Classi production database\|not marked production" "$W/out" && ok "the real file (production's cluster id) is refused here" || ko "real file: $(grep -m1 ERROR "$W/out")"; }
applies apply_0_tracking.sql "step 0: tracking + marker"
refused "$(file apply 03)" "newest recorded migration must be" "step 3 before step 2"
refused "$(file rollback 02)" "newest recorded migration must be" "a rollback of a step not applied"

# 4. forward: every step once, in order; twice is refused; the two gates hold until their condition is met
i=1
for nn in 01 02 03 04 05 06 07 08 09 10 11 12; do
  f=$(file apply $nn); v=$(echo "$f" | cut -d_ -f3)
  if [ "$nn" = 10 ]; then
    refused "$f" "not marked as deployed" "step 10 before the private-photos app is marked deployed"
    applies mark_private_photos_app_deployed.sql "mark: private-photos app deployed"
  fi
  if [ "$nn" = 12 ]; then
    refused "$f" "has not handled a wake-up" "step 12 (D-08 B) without a wake-up"
    $P -d "$DB" -c "insert into public.app_secrets values ('d08_worker_seen_at', (now() - interval '25 hours')::text) on conflict (key) do update set value = excluded.value" >/dev/null
    refused "$f" "has not handled a wake-up" "step 12 with a wake-up older than 24 hours"
    $P -d "$DB" -c "update public.app_secrets set value = now()::text where key = 'd08_worker_seen_at'" >/dev/null
  fi
  applies "$f" "step $nn applies ($v)"
  [ "$(q "select count(*) || ' ' || max(version) from supabase_migrations.schema_migrations")" = "$((25 + i)) $v" ] && ok "step $nn recorded" || ko "step $nn record"
  refused "$f" "already recorded\|newest recorded migration must be" "step $nn twice"
  i=$((i + 1))
done
full=$(state)
[ "$(q "select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('claim_push','claim_otp','log_sms','drop_push_subscriptions')")" = 0 ] \
  && ok "after step 12: the old dispatch functions are gone (TM-13)" || ko "old dispatch functions"
[ "$(q "select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'otp_outbox' and column_name = 'otp'")" = 0 ] \
  && ok "after step 12: no plaintext OTP column (TM-14)" || ko "otp column"
[ "$(q "select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity")" = 0 ] && ok "RLS on every public table at the end" || ko "RLS"

# 5. a tampered schema is refused (on a copy: one function changed after step 12; its rollback must refuse)
$P -c "drop database if exists ${DB}_t" -c "create database ${DB}_t template $DB" >/dev/null 2>&1
MAIN=$DB; DB=${DB}_t
$P -d "$DB" -c "create or replace function public.clean_phone(p text) returns text language sql immutable set search_path = public as \$\$ select p \$\$" >/dev/null
refused "$(file rollback 12)" "not the expected one" "rollback 12 on a changed schema"
$P -d "$DB" -c "alter table public.reviews add column extra int" >/dev/null
refused "$(file rollback 12)" "not the expected one" "rollback 12 with an extra column"
DB=$MAIN; $P -c "drop database if exists ${DB}_t" >/dev/null 2>&1
[ "$(state)" = "$full" ] && ok "the real test database was not touched by the tamper checks" || ko "test database changed"

# 6. one step back and forward again (direct path), then the whole chain back to step 1
applies "$(file rollback 12)" "rollback 12"
applies "$(file apply 12)" "step 12 again after its rollback"
[ "$(state)" = "$full" ] && ok "same state as the first time" || ko "state after rollback + re-apply"
for nn in 12 11 10 09 08 07 06 05 04 03 02; do
  applies "$(file rollback $nn)" "chain rollback $nn"
done
[ "$(q "select count(*) || ' ' || max(version) from supabase_migrations.schema_migrations")" = "26 20261031000000" ] && ok "after the chain: only step 1 recorded" || ko "chain end record"
refused "$(file rollback 03)" "newest recorded migration must be" "rollback 3 when step 3 is not applied"

# 7. step 0 rollback refuses while steps are recorded
refused rollback_0_tracking.sql "refusing (before)" "step 0 rollback while step 1 is recorded"

$P -c "drop database if exists $DB" >/dev/null 2>&1
echo "production files: $pass passed, $fail failed"
[ "$fail" = 0 ]
