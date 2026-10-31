# Database tests

Local only: a Postgres 16 server on `/var/tmp/pgc`, port 54329. Never point these scripts at a real Supabase project.
The test database is built from every migration, then `seed.sql`, then `grants.sql` (test helpers only). Supabase's default privileges are mirrored in `supabase_stub.sql`, so the tests see what production sees.

| Command | What it does |
|---|---|
| `sh supabase/tests/run_all.sh` | Runs every `*_test.sql` suite, each in its own database, 4 at a time. It fails on a different number of expected refusals (see `expected_errors.txt`) or on any `FAIL:` line |
| `sh supabase/tests/run.sh <suite>` | Runs one suite and prints its output |
| `sh supabase/tests/concurrency_test.sh` | Two real connections at the same moment: payment confirmations, institute slots, teacher slots |
| `sh supabase/tests/check_rpc_grants.sh` | Checks that every `rpc("…")` in the app is executable by `authenticated` |
| `sh tests/run-unit.sh` | Unit tests for `lib/*.ts` (Node test runner) |

`security_test.sql` is written as assertions (`PASS:` / `FAIL:`). The older suites print results; their `ERROR` lines are refusals the suite expects.
