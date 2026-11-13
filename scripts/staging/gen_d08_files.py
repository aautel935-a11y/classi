#!/usr/bin/env python3
"""Generates the guarded classi-staging files of D-08 (steps A and B, apply and rollback of each) from the committed
migrations and rollbacks. Same model as gen_private_photos_files.py.

The expected states are read from a LOCAL database built from the committed migrations (never a hosted one):
  S0 = after 20261105010000 (before D-08), S1 = after A, S2 = after B. Each file checks the FULL state of everything D-08
  touches (the secret-gated and worker functions with their body checksum, search_path, SECURITY DEFINER and who may
  execute them: anon, authenticated, service_role; the otp_outbox columns) before any change and again before commit;
  any difference rolls everything back.
Step B also refuses unless the new app code has handled a wake-up with the server key within the last 24 hours
(app_secrets d08_worker_seen_at, written by worker_wake_ok): proof that the routes no longer need the old functions.

Usage (local Postgres, as in supabase/tests): python3 scripts/staging/gen_d08_files.py [--check]
Then: sh supabase/tests/staging_d08_test.sh   (CI checks that the committed files are up to date).
"""
import os, subprocess, sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOCK = os.environ.get("PGSOCK", "/var/tmp/pgc"); PORT = os.environ.get("PGPORT", "54329")
DB = "ct_gen_d08"
STAGING_ID = "7702070854497379551"
PREV, A, B = "20261105010000", "20261114000000", "20261114010000"
A_FILE, B_FILE = "20261114000000_d08_workers", "20261114010000_d08_enforce"
FNS = ["send_sms_hook", "claim_push", "claim_otp", "log_sms", "drop_push_subscriptions", "notifications_mark_push",
       "worker_wake_ok", "worker_claim_push", "worker_push_keys", "worker_drop_push_subscriptions", "worker_log_sms", "worker_claim_otp"]

EXPR = {
    "FN": ("coalesce((select string_agg(format('%s(%s)|%s|%s|%s|anon=%s|authenticated=%s|service_role=%s', p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid), "
           "md5(p.prosrc), coalesce(array_to_string(p.proconfig, ','), '-'), p.prosecdef, has_function_privilege('anon', p.oid, 'execute'), "
           "has_function_privilege('authenticated', p.oid, 'execute'), has_function_privilege('service_role', p.oid, 'execute')), E'\\n' order by p.proname) "
           "from pg_catalog.pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in (" + ", ".join(f"'{f}'" for f in FNS) + ")), '')"),
    "COL": ("coalesce((select string_agg(column_name::text, ',' order by column_name) from information_schema.columns "
            "where table_schema = 'public' and table_name = 'otp_outbox'), '')"),
}
LABEL = {"FN": "the dispatch functions (body, search_path, definer, execute rights)", "COL": "the otp_outbox columns"}


def psql(*args, db=DB):
    cmd = ["psql", "-h", SOCK, "-p", PORT, "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-At", "-d", db] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, env=dict(os.environ, PGOPTIONS="-c client_min_messages=warning"))
    if r.returncode != 0:
        sys.exit(f"psql failed: {' '.join(args)[:200]}\n{r.stderr}")
    return r.stdout


def state():
    return {k: psql("-c", f"select {e}").rstrip("\n") for k, e in EXPR.items()}


def read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read()


def body_of_down(rel):
    return "".join(l for l in read(rel).splitlines(True) if not l.startswith("--") and l.strip() not in ("begin;", "commit;"))


def dq(text):
    assert "$exp$" not in text
    return "$exp$" + text + "$exp$"


def check(key, expected, verb):
    msg = ("refusing" if verb == "guard" else "aborting") + f": {LABEL[key]} are not the expected state"
    if verb != "guard":
        msg += "; everything is rolled back"
    return (f"  v := {EXPR[key]};\n"
            f"  if v is distinct from {dq(expected)} then raise exception E'{msg}. Found:\\n%', v; end if;\n")


def identity():
    return (f"  if (select system_identifier from pg_catalog.pg_control_system()) <> {STAGING_ID} then raise exception 'refusing: not the classi-staging database'; end if;\n"
            "  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then raise exception 'refusing: database not marked staging'; end if;\n"
            "  if exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity)\n"
            "    then raise exception 'refusing: a public table has row level security off'; end if;\n"
            "  if exists (select 1 from pg_catalog.pg_roles where rolname in ('anon', 'authenticated') and rolbypassrls) then raise exception 'refusing: anon or authenticated bypasses row level security'; end if;\n")


def newest(version, verb="guard"):
    word = "refusing" if verb == "guard" else "aborting"
    return (f"  if (select max(version) from supabase_migrations.schema_migrations) is distinct from '{version}' then raise exception '{word}: the newest recorded migration is not {version} (found %)', (select max(version) from supabase_migrations.schema_migrations); end if;\n"
            f"  if (select count(*) from supabase_migrations.schema_migrations where version = '{version}') <> 1 then raise exception '{word}: {version} is not recorded exactly once'; end if;\n")


def block(name, lines):
    return f"do ${name}$\ndeclare v text;\nbegin\n{lines}end ${name}$;\n"


def main():
    psql("-c", f"drop database if exists {DB}", "-c", f"create database {DB}", db="postgres")
    psql("-f", os.path.join(REPO, "supabase/tests/supabase_stub.sql"))
    for f in sorted(os.listdir(os.path.join(REPO, "supabase/migrations"))):
        if f.split("_")[0] > PREV:
            break
        psql("-f", os.path.join(REPO, "supabase/migrations", f))
    s0 = state()
    psql("-f", os.path.join(REPO, f"supabase/migrations/{A_FILE}.sql")); s1 = state()
    psql("-f", os.path.join(REPO, f"supabase/migrations/{B_FILE}.sql")); s2 = state()
    psql("-f", os.path.join(REPO, f"supabase/rollback/{B_FILE}.down.sql"))
    if state() != s1:
        sys.exit("rolling B back does not give the state after A: fix the rollback first")
    psql("-f", os.path.join(REPO, f"supabase/rollback/{A_FILE}.down.sql"))
    if state() != s0:
        sys.exit("rolling A back does not give the state before A: fix the rollback first")
    psql("-c", f"drop database if exists {DB}", db="postgres")

    head = "-- GENERATED by scripts/staging/gen_d08_files.py from the committed migration and rollback files. Do not edit.\n"
    seen = ("  if not exists (select 1 from public.app_secrets where key = 'd08_worker_seen_at' and value::timestamptz > now() - interval '24 hours')\n"
            "    then raise exception 'refusing: the new dispatch code has not handled a wake-up with the server key in the last 24 hours (app_secrets d08_worker_seen_at). Deploy it, set SUPABASE_SERVICE_ROLE_KEY, and let one notification or sign-in code go out first'; end if;\n")

    # ---------- apply A ----------
    guard = identity()
    guard += f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{A}') then raise exception 'refusing: {A} is already recorded'; end if;\n"
    guard += newest(PREV) + check("FN", s0["FN"], "guard") + check("COL", s0["COL"], "guard")
    post = newest(A, "check") + check("FN", s1["FN"], "check") + check("COL", s1["COL"], "check")
    apply_a = (head +
               f"-- classi-staging ONLY: applies migration {A_FILE} (D-08 step A: server-only worker functions, 5-minute codes,\n"
               "-- email fallback only to a confirmed email) in one transaction, recorded once. Additive: the current app keeps working.\n"
               "-- Run in Supabase -> project classi-staging -> SQL Editor, never through a workflow. Any error rolls everything back.\n"
               f"-- Refuses before any change unless: the classi-staging cluster id and marker; the newest migration is exactly {PREV};\n"
               "-- RLS on every public table, no bypass; the dispatch functions (body checksum, search_path, definer, execute rights for\n"
               "-- anon, authenticated, service_role) and the otp_outbox columns exactly as before D-08. Before commit it checks the full\n"
               "-- state after step A the same way. Order: this file, then the app code (+ SUPABASE_SERVICE_ROLE_KEY in Vercel), then B.\n"
               f"-- Rollback: rollback_{A_FILE}.sql\n"
               "begin;\n" + block("guard", guard) +
               f"-- ===== BEGIN MIGRATION supabase/migrations/{A_FILE}.sql =====\n" + read(f"supabase/migrations/{A_FILE}.sql") + "-- ===== END MIGRATION =====\n" +
               f"insert into supabase_migrations.schema_migrations (version, name) values ('{A}', 'd08_workers');\n" +
               block("check", post) + "commit;\n-- expected result: \"Success. No rows returned\"\n")

    # ---------- rollback A ----------
    guard = identity() + newest(A)
    guard += f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{B}') then raise exception 'refusing: step B is recorded: roll it back first'; end if;\n"
    guard += check("FN", s1["FN"], "guard") + check("COL", s1["COL"], "guard")
    post = newest(PREV, "check") + check("FN", s0["FN"], "check") + check("COL", s0["COL"], "check")
    rollback_a = (head +
                  f"-- classi-staging ONLY: rolls back {A_FILE} (D-08 step A) in ONE transaction: the worker functions, the step\n"
                  "-- marker and the migration record go, the Auth hook of 20261031000000 comes back. Run in Supabase -> classi-staging ->\n"
                  f"-- SQL Editor. Refuses unless: classi-staging; {A} is the newest migration (B not recorded); the state is exactly the one\n"
                  "-- step A leaves. Before commit it checks that the state is exactly the one before step A. The app keeps working only if\n"
                  "-- it can fall back to the old path: remove SUPABASE_SERVICE_ROLE_KEY or redeploy the older app first.\n"
                  "begin;\n" + block("guard", guard) +
                  f"-- ===== BEGIN ROLLBACK supabase/rollback/{A_FILE}.down.sql =====\n" + body_of_down(f"supabase/rollback/{A_FILE}.down.sql") +
                  "-- ===== END ROLLBACK =====\n" +
                  f"delete from supabase_migrations.schema_migrations where version = '{A}';\n" +
                  block("check", post) + "commit;\n-- expected result: \"Success. No rows returned\"\n")

    # ---------- apply B ----------
    guard = identity()
    guard += f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{B}') then raise exception 'refusing: {B} is already recorded'; end if;\n"
    guard += newest(A) + seen + check("FN", s1["FN"], "guard") + check("COL", s1["COL"], "guard")
    post = newest(B, "check") + check("FN", s2["FN"], "check") + check("COL", s2["COL"], "check")
    apply_b = (head +
               f"-- classi-staging ONLY: applies migration {B_FILE} (D-08 step B: the old anon dispatch functions and the otp\n"
               "-- column are removed) in one transaction. Run in Supabase -> project classi-staging -> SQL Editor, never through a\n"
               f"-- workflow. Refuses unless: classi-staging; the newest migration is exactly {A} (step A); the new dispatch code handled\n"
               "-- a wake-up with the server key in the last 24 hours (d08_worker_seen_at); the full state is exactly the one step A\n"
               f"-- leaves. Before commit it checks the state after B. Rollback: rollback_{B_FILE}.sql\n"
               "begin;\n" + block("guard", guard) +
               f"-- ===== BEGIN MIGRATION supabase/migrations/{B_FILE}.sql =====\n" + read(f"supabase/migrations/{B_FILE}.sql") +
               "-- ===== END MIGRATION =====\n" +
               f"insert into supabase_migrations.schema_migrations (version, name) values ('{B}', 'd08_enforce');\n" +
               block("check", post) + "commit;\n-- expected result: \"Success. No rows returned\"\n")

    # ---------- rollback B ----------
    guard = identity() + newest(B) + check("FN", s2["FN"], "guard") + check("COL", s2["COL"], "guard")
    post = newest(A, "check") + check("FN", s1["FN"], "check") + check("COL", s1["COL"], "check")
    rollback_b = (head +
                  f"-- classi-staging ONLY: rolls back {B_FILE} (D-08 step B) in ONE transaction: the four secret-gated anon functions,\n"
                  "-- the otp column and the step-A Auth hook come back, and the migration record goes, together. Run in Supabase ->\n"
                  f"-- classi-staging -> SQL Editor. Refuses unless: classi-staging; {B} is the newest migration; the state is exactly the one\n"
                  "-- step B leaves. Before commit it checks that the state is exactly the one after step A. Roll B back BEFORE the app code.\n"
                  "begin;\n" + block("guard", guard) +
                  f"-- ===== BEGIN ROLLBACK supabase/rollback/{B_FILE}.down.sql =====\n" + body_of_down(f"supabase/rollback/{B_FILE}.down.sql") +
                  "-- ===== END ROLLBACK =====\n" +
                  f"delete from supabase_migrations.schema_migrations where version = '{B}';\n" +
                  block("check", post) + "commit;\n-- expected result: \"Success. No rows returned\"\n")

    out = {f"supabase/staging/apply_{A_FILE}.sql": apply_a, f"supabase/staging/rollback_{A_FILE}.sql": rollback_a,
           f"supabase/staging/apply_{B_FILE}.sql": apply_b, f"supabase/staging/rollback_{B_FILE}.sql": rollback_b}
    check_only = "--check" in sys.argv
    stale = []
    for rel, text in out.items():
        path = os.path.join(REPO, rel)
        cur = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if cur != text:
            stale.append(rel)
            if not check_only:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text)
    if check_only:
        print("up to date" if not stale else "STALE: " + ", ".join(stale))
        sys.exit(1 if stale else 0)
    print("written:", ", ".join(stale) if stale else "nothing (up to date)")


if __name__ == "__main__":
    main()
