#!/bin/sh
# Fresh database, apply schema + seed, run the flow test.
set -e
P="psql -h /var/tmp/pgc -p 54329 -U postgres -q"
$P -c "drop database if exists classi_test" -c "create database classi_test"
D="$P -d classi_test -v ON_ERROR_STOP=1"
$P -d classi_test -c "drop role if exists anon" -c "drop role if exists authenticated" -c "drop role if exists service_role" 2>/dev/null || true
$D -f "$(dirname "$0")/supabase_stub.sql"
$D -f "$(dirname "$0")/../migrations/20261024000000_init.sql"
$D -f "$(dirname "$0")/../migrations/20261024010000_photos_admin.sql"
$D -f "$(dirname "$0")/../migrations/20261024020000_role_test_fixes.sql"
$D -f "$(dirname "$0")/../migrations/20261024030000_edit_and_messages.sql"
$D -f "$(dirname "$0")/../seed.sql"
$D -f "$(dirname "$0")/grants.sql"
$P -d classi_test -f "$(dirname "$0")/${1:-flow_test}.sql"
