#!/bin/sh
# Every RPC the app calls must be executable by "authenticated" after all migrations (audit SEC-01 keeps
# EXECUTE to an allow-list, so a new rpc("…") in the app needs a grant in a migration). Exits 1 if one is missing.
T="$(cd "$(dirname "$0")" && pwd)"; R="$T/../.."
P="psql -h ${PGSOCK:-/var/tmp/pgc} -p ${PGPORT:-54329} -U postgres -q"
DB=ct_rpc_grants sh "$T/run.sh" today_test >/dev/null 2>&1 || { echo "FAIL: could not build the test database"; exit 1; }
grep -rhoE 'rpc\(\s*"[a-z_]+"' "$R/app" "$R/lib" "$R/components" | sed -E 's/.*"([a-z_]+)"/\1/' | sort -u > /tmp/classi_app_rpcs.txt
$P -d ct_rpc_grants -At -c "select proname from pg_proc where pronamespace = 'public'::regnamespace and has_function_privilege('authenticated', oid, 'execute')" | sort -u > /tmp/classi_granted.txt
$P -c "drop database if exists ct_rpc_grants" >/dev/null
missing=$(comm -23 /tmp/classi_app_rpcs.txt /tmp/classi_granted.txt)
if [ -n "$missing" ]; then echo "FAIL: called by the app but not granted to authenticated: $missing"; exit 1; fi
echo "PASS: all $(wc -l < /tmp/classi_app_rpcs.txt) RPCs called by the app are granted"
