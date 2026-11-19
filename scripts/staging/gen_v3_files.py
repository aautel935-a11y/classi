#!/usr/bin/env python3
"""Generates the guarded classi-staging files of Classi v3 from the committed migrations and rollbacks:

  apply_20261120000000_v3_ledger.sql            apply_20261120010000_v3_business_access.sql
  rollback_20261120010000_v3_business_access.sql rollback_20261120000000_v3_ledger.sql
  rollback_..._discard_data.sql (one per step)  verify_v3.sql   snapshot_v3.sql

Same model as gen_d08_files.py. The expected states come from a LOCAL database built from the committed migrations
(never a hosted one): S0 = before v3 (after D-08 step A; checked to be the same after step B), S1 = after the ledger,
S2 = after business access. Each apply/rollback file checks, before any change and again before commit, the FULL state of
everything v3 touches: every v3 function and the three it replaces (body checksum, search_path, SECURITY DEFINER, who may
execute: anon, authenticated, service_role), the six v3 tables (RLS, privileges of anon/authenticated, policies), the v3
triggers, the subscriptions columns and the three v3 settings. Any difference rolls everything back.

v3 does not depend on D-08 step B: the apply file accepts either 20261114000000 (A) or 20261114010000 (B) as the newest
migration. NOTE: D-08's own apply_B file expects A to be the newest; if v3 goes first, that file must be regenerated.

Rollbacks refuse while v3 tables hold rows (data would be lost). The *_discard_data variants do the same rollback and
delete those rows; they print what they delete and are meant only for test data or after an export.

Usage (local Postgres, as in supabase/tests): python3 scripts/staging/gen_v3_files.py [--check]
Then: sh supabase/tests/staging_v3_test.sh   (CI checks that the committed files are up to date).
"""
import os
import re, subprocess, sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOCK = os.environ.get("PGSOCK", "/var/tmp/pgc"); PORT = os.environ.get("PGPORT", "54329")
# Local test server only: PGSOCK is a plain absolute socket directory or a loopback host (CI's PostgreSQL 17 service),
# and the port a number. They reach psql as list arguments, never through a shell.
if not (re.fullmatch(r"/[A-Za-z0-9_./-]{1,200}", SOCK) and ".." not in SOCK or SOCK in ("127.0.0.1", "localhost", "::1")) \
        or not re.fullmatch(r"\d{2,5}", PORT):
    sys.exit("PGSOCK must be an absolute socket directory or a loopback host, and PGPORT a port number")
DB = "ct_gen_v3"
STAGING_ID = "7702070854497379551"
D08_A, D08_B = "20261114000000", "20261114010000"
L, S = "20261120000000", "20261120010000"
L_FILE, S_FILE = "20261120000000_v3_ledger", "20261120010000_v3_business_access"
TABLES = ["audit_log", "business_exemptions", "business_trials", "charges", "payments", "staff_permissions"]
L_TABLES = ["charges", "payments", "audit_log", "staff_permissions"]
S_TABLES = ["business_trials", "business_exemptions"]
TRIGGERS = ["audit_log_append_only", "institutes_start_trial", "payments_append_only", "teachers_start_trial"]
SETTINGS = ["grace_days", "launch_at", "trial_days"]


def v3_functions():
    names = set()
    for f in (L_FILE, S_FILE):
        names |= set(re.findall(r"function public\.([a-z_0-9]+)", read(f"supabase/migrations/{f}.sql")))
    return sorted(names)


def read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read()


def q(names):
    return ", ".join(f"'{n}'" for n in names)


def exprs():
    fns = v3_functions()
    return {
        "FN": ("coalesce((select string_agg(format('%s(%s)|%s|%s|%s|anon=%s|authenticated=%s|service_role=%s', p.proname, pg_catalog.pg_get_function_identity_arguments(p.oid), "
               "md5(p.prosrc), coalesce(array_to_string(p.proconfig, ','), '-'), p.prosecdef, has_function_privilege('anon', p.oid, 'execute'), "
               "has_function_privilege('authenticated', p.oid, 'execute'), has_function_privilege('service_role', p.oid, 'execute')), E'\\n' order by p.proname, 2) "
               f"from pg_catalog.pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ({q(fns)})), '')"),
        "TBL": ("coalesce((select string_agg(format('%s|rls=%s|anon=%s|authenticated=%s|policies=%s', c.relname, c.relrowsecurity, "
                "has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE'), has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE'), "
                "(select count(*) from pg_catalog.pg_policy po where po.polrelid = c.oid)), E'\\n' order by c.relname) "
                f"from pg_catalog.pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname in ({q(TABLES)})), '')"),
        "TRG": ("coalesce((select string_agg(format('%s.%s|%s', t.tgrelid::regclass, t.tgname, t.tgenabled), E'\\n' order by t.tgname) "
                f"from pg_catalog.pg_trigger t where not t.tgisinternal and t.tgname in ({q(TRIGGERS)})), '')"),
        "COL": ("coalesce((select string_agg(column_name::text, ',' order by column_name) from information_schema.columns "
                "where table_schema = 'public' and table_name = 'subscriptions'), '')"),
        "SET": (f"coalesce((select string_agg(key || '=' || value, ',' order by key) from public.app_settings where key in ({q(SETTINGS)})), '')"),
    }


LABEL = {"FN": "the v3 functions and the three it replaces (body, search_path, definer, execute rights)",
         "TBL": "the v3 tables (RLS, privileges, policies)", "TRG": "the v3 triggers", "COL": "the subscriptions columns",
         "SET": "the v3 settings"}


def psql(*args, db=DB):
    cmd = ["psql", "-h", SOCK, "-p", PORT, "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-At", "-d", db] + list(args)
    # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args -- list argv, no shell, PGSOCK/PGPORT validated above, local test server only
    r = subprocess.run(cmd, capture_output=True, text=True, env=dict(os.environ, PGOPTIONS="-c client_min_messages=warning"))
    if r.returncode != 0:
        sys.exit(f"psql failed: {' '.join(args)[:200]}\n{r.stderr}")
    return r.stdout


def state(db=DB):
    return {k: psql("-c", f"select {e}", db=db).rstrip("\n") for k, e in exprs().items()}


def body_of_down(rel):
    return "".join(l for l in read(rel).splitlines(True) if not l.startswith("--") and l.strip() not in ("begin;", "commit;"))


def dq(text):
    assert "$exp$" not in text
    return "$exp$" + text + "$exp$"


def check(key, expected, verb):
    msg = ("refusing" if verb == "guard" else "aborting") + f": {LABEL[key]} are not the expected state"
    if verb != "guard":
        msg += "; everything is rolled back"
    return (f"  v := {exprs()[key]};\n"
            f"  if v is distinct from {dq(expected)} then raise exception E'{msg}. Found:\\n%', v; end if;\n")


def checks(st, verb):
    return "".join(check(k, st[k], verb) for k in exprs())


def identity():
    return (f"  if (select system_identifier from pg_catalog.pg_control_system()) <> {STAGING_ID} then raise exception 'refusing: not the classi-staging database'; end if;\n"
            "  if not exists (select 1 from public.app_secrets where key = 'deploy_env' and value = 'staging') then raise exception 'refusing: database not marked staging'; end if;\n"
            "  if exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity)\n"
            "    then raise exception 'refusing: a public table has row level security off'; end if;\n"
            "  if exists (select 1 from pg_catalog.pg_roles where rolname in ('anon', 'authenticated') and rolbypassrls) then raise exception 'refusing: anon or authenticated bypasses row level security'; end if;\n"
            "  if coalesce((select value from public.app_settings where key = 'subscriptions_required'), 'false') <> 'false' then raise exception 'refusing: subscriptions_required is on; v3 is rolled out with it off'; end if;\n")


def newest_in(versions, verb="guard"):
    word = "refusing" if verb == "guard" else "aborting"
    lst = ", ".join(versions)
    return (f"  if (select max(version) from supabase_migrations.schema_migrations) not in ({q(versions)}) then raise exception '{word}: the newest recorded migration is not {lst} (found %)', (select max(version) from supabase_migrations.schema_migrations); end if;\n"
            f"  if (select count(*) from supabase_migrations.schema_migrations where version = (select max(version) from supabase_migrations.schema_migrations)) <> 1 then raise exception '{word}: the newest migration is not recorded exactly once'; end if;\n")


def not_recorded(version):
    return f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{version}') then raise exception 'refusing: {version} is already recorded'; end if;\n"


def empty_tables(tables, extra=""):
    cond = " or ".join(f"exists (select 1 from public.{t})" for t in tables) + extra
    counts = ", ".join(f"'{t}=' || (select count(*) from public.{t})" for t in tables)
    return (f"  if {cond} then raise exception 'refusing: v3 data would be lost (%). Export it first (backup, or the CSV export), then use the _discard_data file', concat_ws(', ', {counts}); end if;\n")


def report_rows(tables):
    return ("select " + ", ".join(f"(select count(*) from public.{t}) as {t}_rows_deleted" for t in tables) + ";\n")


def block(name, lines):
    return f"do ${name}$\ndeclare v text;\nbegin\n{lines}end ${name}$;\n"


HEAD = "-- GENERATED by scripts/staging/gen_v3_files.py from the committed migration and rollback files. Do not edit.\n"
END = "commit;\n-- expected result: \"Success. No rows returned\"\n"


def apply_file(step_file, version, name, prev_versions, before, after, what):
    guard = identity() + not_recorded(version) + newest_in(prev_versions) + checks(before, "guard")
    post = newest_in([version], "check") + checks(after, "check")
    return (HEAD +
            f"-- classi-staging ONLY: applies migration {step_file} ({what}) in one transaction, recorded once.\n"
            "-- Additive: no existing data changes. Run in Supabase -> project classi-staging -> SQL Editor, never through a workflow.\n"
            f"-- Refuses before any change unless: the classi-staging cluster id and marker; the newest migration is {' or '.join(prev_versions)};\n"
            "-- RLS on every public table, no bypass; subscriptions_required off; and the full state of everything v3 touches exactly\n"
            "-- as expected. Before commit it checks the state after this step the same way. Any error rolls everything back.\n"
            "begin;\n" + block("guard", guard) +
            f"-- ===== BEGIN MIGRATION supabase/migrations/{step_file}.sql =====\n" + read(f"supabase/migrations/{step_file}.sql") + "-- ===== END MIGRATION =====\n" +
            f"insert into supabase_migrations.schema_migrations (version, name) values ('{version}', '{name}');\n" +
            block("check", post) + END)


def rollback_file(step_file, version, back_to_versions, before, after, tables, discard, extra_cond="", note=""):
    guard = identity() + newest_in([version]) + checks(before, "guard")
    if not discard:
        guard += empty_tables(tables, extra_cond)
    post = newest_in(back_to_versions, "check") + checks(after, "check")
    kind = "deletes the v3 rows listed below, then rolls back" if discard else "refuses while v3 tables hold any row"
    return (HEAD +
            f"-- classi-staging ONLY: rolls back {step_file} in ONE transaction ({kind}). Run in Supabase -> classi-staging ->\n"
            f"-- SQL Editor. Refuses unless: classi-staging; {version} is the newest migration; the state is exactly the one this step\n"
            "-- leaves. Before commit it checks that the state is exactly the one before this step.\n" + note +
            "begin;\n" + block("guard", guard) +
            (report_rows(tables) if discard else "") +
            f"-- ===== BEGIN ROLLBACK supabase/rollback/{step_file}.down.sql =====\n" + body_of_down(f"supabase/rollback/{step_file}.down.sql") +
            "-- ===== END ROLLBACK =====\n" +
            f"delete from supabase_migrations.schema_migrations where version = '{version}';\n" +
            block("check", post) + END)


# ---------- read-only snapshot and verification (V1-V6), both end in ROLLBACK ----------
COUNTS = ("(select md5(string_agg(t || '=' || n, ',' order by t)) from (select c.relname::text t, (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text n "
          "from pg_catalog.pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' "
          f"and c.relname not in ({q(TABLES)}, 'app_settings', 'reminder_log', 'notifications')) x)")
SETTINGS_FP = f"(select md5(string_agg(key || '=' || value, ',' order by key)) from public.app_settings where key not in ({q(SETTINGS)}))"
VISIBLE = ("(select md5(concat_ws('|', (select string_agg(id::text, ',' order by id) from public.teachers), "
           "(select string_agg(id::text, ',' order by id) from public.institutes), (select string_agg(id::text, ',' order by id) from public.offerings))))")


def snapshot_sql():
    return (HEAD +
            "-- classi-staging, READ ONLY (ends in ROLLBACK): run BEFORE the v3 apply files and keep the result next to the backup.\n"
            "-- verify_v3.sql prints the same three fingerprints after the apply; they must be equal.\n"
            "begin read only;\n"
            "select 'data (row counts of every pre-v3 table)' as fingerprint, " + COUNTS + " as value\n"
            "union all select 'settings (all but the three v3 keys)', " + SETTINGS_FP + "\n"
            "union all select 'migrations', (select string_agg(version, ',' order by version) from supabase_migrations.schema_migrations);\n"
            "set local role anon;\n"
            "select 'visible to visitors (teachers, institutes, offers)' as fingerprint, " + VISIBLE + " as value;\n"
            "rollback;\n")


def verify_sql(s2):
    fn_ok, tbl_ok, trg_ok = dq(s2["FN"]), dq(s2["TBL"]), dq(s2["TRG"])
    e = exprs()
    probe = "00000000-0000-4000-8000-00000000c1a5"
    return (HEAD +
            "-- classi-staging, READ ONLY (ends in ROLLBACK): V1-V6 after the two v3 apply files. One row per check: PASS / FAIL.\n"
            "-- The three FINGERPRINT rows must equal what snapshot_v3.sql printed before the apply.\n"
            "begin;\n"
            "create temp table v3_check (n int, check_name text, result text, detail text) on commit drop;\n"
            "insert into v3_check select 1, 'V1 migrations recorded once, newest is v3', "
            f"case when (select max(version) from supabase_migrations.schema_migrations) = '{S}' and (select count(*) from supabase_migrations.schema_migrations where version in ('{L}','{S}')) = 2 then 'PASS' else 'FAIL' end, "
            "(select string_agg(version, ',' order by version) from supabase_migrations.schema_migrations where version >= '20261114000000');\n"
            f"insert into v3_check select 2, 'V2 v3 tables: RLS on, no anon/authenticated privileges, no policies', case when {e['TBL']} = {tbl_ok} then 'PASS' else 'FAIL' end, {e['TBL']};\n"
            f"insert into v3_check select 2, 'V2 append-only and trial triggers present and enabled', case when {e['TRG']} = {trg_ok} then 'PASS' else 'FAIL' end, {e['TRG']};\n"
            f"insert into v3_check select 3, 'V3 v3 functions exactly as generated (body, search_path, definer, execute rights)', case when {e['FN']} = {fn_ok} then 'PASS' else 'FAIL' end, "
            f"case when {e['FN']} = {fn_ok} then 'match' else 'differs' end;\n"
            "insert into v3_check select 3, 'V3 worker_* functions still service-role only', "
            "case when not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'worker\\_%' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))) then 'PASS' else 'FAIL' end, null;\n"
            "insert into v3_check select 4, 'V4 FINGERPRINT data (must equal the snapshot)', 'COMPARE', " + COUNTS + ";\n"
            "insert into v3_check select 4, 'V4 FINGERPRINT settings (must equal the snapshot)', 'COMPARE', " + SETTINGS_FP + ";\n"
            f"insert into v3_check select 4, 'V4 v3 settings: trial 30, grace 7, no launch date; subscriptions_required off', case when {e['SET']} = 'grace_days=7,launch_at=,trial_days=30' "
            "and coalesce((select value from public.app_settings where key = 'subscriptions_required'), 'false') = 'false' then 'PASS' else 'FAIL' end, " + e['SET'] + ";\n"
            "insert into v3_check select 4, 'V4 v3 tables empty (nothing has used them yet)', case when "
            + " and ".join(f"not exists (select 1 from public.{t})" for t in TABLES) + " then 'PASS' else 'FAIL' end, null;\n"
            "insert into v3_check select 6, 'V6 RLS on every public table, no bypass for anon/authenticated', "
            "case when not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity) "
            "and not exists (select 1 from pg_roles where rolname in ('anon','authenticated') and rolbypassrls) then 'PASS' else 'FAIL' end, null;\n"
            "insert into v3_check select 6, 'V6 private photos bucket still private', case when exists (select 1 from storage.buckets where id = 'photos-private' and not public) then 'PASS' else 'FAIL' end, null;\n"
            "-- V6 isolation, as a signed-in stranger and as a visitor (role switched inside this transaction only)\n"
            "do $iso$\ndeclare n1 int; n2 int; n3 int; n4 int; ok boolean; vis text;\nbegin\n"
            f"  perform set_config('request.jwt.claim.sub', '{probe}', true);\n"
            "  execute 'set local role authenticated';\n"
            "  select count(*) into n1 from public.business_charges();\n"
            "  select count(*) into n2 from public.my_charges();\n"
            "  select count(*) into n3 from public.my_ledger_businesses();\n"
            "  select count(*) into n4 from public.admin_business_access();\n"
            "  begin perform 1 from public.charges limit 1; ok := false; exception when insufficient_privilege then ok := true; end;\n"
            "  execute 'reset role';\n"
            "  insert into v3_check values (6, 'V6 a signed-in stranger sees no charges, no businesses, no admin list; no direct table access', "
            "case when n1 + n2 + n3 + n4 = 0 and ok then 'PASS' else 'FAIL' end, format('charges=%s mine=%s businesses=%s admin=%s direct_denied=%s', n1, n2, n3, n4, ok));\n"
            "  execute 'set local role anon';\n"
            "  begin perform public.create_charge(null, null, 'x', 'y', 1); ok := false; exception when insufficient_privilege then ok := true; end;\n"
            "  execute 'reset role';\n"
            "  insert into v3_check values (6, 'V6 a visitor cannot call the ledger functions', case when ok then 'PASS' else 'FAIL' end, null);\n"
            "  execute 'set local role anon';\n"
            "  select " + VISIBLE + " into vis;\n"
            "  execute 'reset role';\n"
            "  insert into v3_check values (5, 'V5 FINGERPRINT visible to visitors (must equal the snapshot)', 'COMPARE', vis);\n"
            "end $iso$;\n"
            "select check_name, result, detail from v3_check order by n, check_name;\n"
            "rollback;\n")


def main():
    psql("-c", f"drop database if exists {DB}", "-c", f"create database {DB}", db="postgres")
    psql("-f", os.path.join(REPO, "supabase/tests/supabase_stub.sql"))
    for f in sorted(os.listdir(os.path.join(REPO, "supabase/migrations"))):
        if f.split("_")[0] > D08_A:
            break
        psql("-f", os.path.join(REPO, "supabase/migrations", f))
    s0 = state()
    # the v3 state does not depend on D-08 step B: same S0 with B applied
    psql("-f", os.path.join(REPO, "supabase/migrations/20261114010000_d08_enforce.sql"))
    if state() != s0:
        sys.exit("D-08 step B changes something v3 checks: the apply file cannot accept both A and B")
    psql("-f", os.path.join(REPO, "supabase/rollback/20261114010000_d08_enforce.down.sql"))
    psql("-f", os.path.join(REPO, f"supabase/migrations/{L_FILE}.sql")); s1 = state()
    psql("-f", os.path.join(REPO, f"supabase/migrations/{S_FILE}.sql")); s2 = state()
    psql("-f", os.path.join(REPO, f"supabase/rollback/{S_FILE}.down.sql"))
    if state() != s1:
        sys.exit("rolling business access back does not give the state after the ledger: fix the rollback first")
    psql("-f", os.path.join(REPO, f"supabase/rollback/{L_FILE}.down.sql"))
    if state() != s0:
        sys.exit("rolling the ledger back does not give the state before v3: fix the rollback first")
    psql("-c", f"drop database if exists {DB}", db="postgres")

    prev = [D08_A, D08_B]
    lost_s = ("-- DATA LOST by the _discard_data variant: trial rows, exemptions, list prices and discount reasons of subscriptions,\n"
              "-- the trial_days / grace_days / launch_at settings. Subscriptions themselves and every other table are kept.\n")
    lost_l = ("-- DATA LOST by the _discard_data variant: every charge, payment, correction, audit-log row and staff permission.\n"
              "-- Customers' bookings and the old pay_status of bookings and packages are kept.\n")
    out = {
        f"supabase/staging/apply_{L_FILE}.sql": apply_file(L_FILE, L, "v3_ledger", prev, s0, s1, "v3: customer payments ledger, audit log, staff permissions"),
        f"supabase/staging/apply_{S_FILE}.sql": apply_file(S_FILE, S, "v3_business_access", [L], s1, s2, "v3: free trial, grace, exemptions, discounts, reminders"),
        f"supabase/staging/rollback_{S_FILE}.sql": rollback_file(S_FILE, S, [L], s2, s1, S_TABLES, False,
            " or exists (select 1 from public.subscriptions where list_price is not null or discount_reason is not null)", lost_s),
        f"supabase/staging/rollback_{S_FILE}_discard_data.sql": rollback_file(S_FILE, S, [L], s2, s1, S_TABLES, True, note=lost_s),
        f"supabase/staging/rollback_{L_FILE}.sql": rollback_file(L_FILE, L, prev, s1, s0, L_TABLES, False, note=lost_l),
        f"supabase/staging/rollback_{L_FILE}_discard_data.sql": rollback_file(L_FILE, L, prev, s1, s0, L_TABLES, True, note=lost_l),
        "supabase/staging/snapshot_v3.sql": snapshot_sql(),
        "supabase/staging/verify_v3.sql": verify_sql(s2),
    }
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
