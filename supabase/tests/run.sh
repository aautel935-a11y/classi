#!/bin/sh
# Fresh database, apply schema + seed, run one test file (default: flow_test).
#   sh supabase/tests/run.sh roles_test            -> database classi_test
#   DB=ct_roles sh supabase/tests/run.sh roles_test -> its own database (lets suites run side by side)
# Requires a local Postgres on /var/tmp/pgc:54329 (see README). Never point this at a real Supabase project.
set -e
T="$(cd "$(dirname "$0")" && pwd)"
DB=${DB:-classi_test}
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q"
$P -c "drop database if exists $DB" -c "create database $DB" >/dev/null
D="env PGOPTIONS=-cclient_min_messages=warning $P -d $DB -v ON_ERROR_STOP=1"
$D -f "$T/supabase_stub.sql" >/dev/null
# Every migration, in file-name order (the same order Supabase applies them).
for f in "$T"/../migrations/*.sql; do $D -f "$f" >/dev/null; done
$D -f "$T/../seed.sql" >/dev/null
$D -f "$T/grants.sql" >/dev/null
$P -d $DB -f "$T/${1:-flow_test}.sql"
