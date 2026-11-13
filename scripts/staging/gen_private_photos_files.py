#!/usr/bin/env python3
"""Generates the guarded classi-staging files of the private-photo steps A and B (apply and rollback of each, and the
"app deployed" marker files) from the committed migrations and rollbacks.

The expected states are read from a LOCAL database built from the committed migrations (never a hosted one):
  S0 = after 20261104000000 (before A), S1 = after A, S2 = after B, S0k = after rolling A back (S0 + the kept bucket
  and column). Each file checks the FULL state (storage.objects policies in full, the functions involved with their
  body checksum, search_path, SECURITY DEFINER and who may execute them, buckets, triggers, the avatar_path column) before
  any change, and again before commit; any difference rolls everything back.

Usage (local Postgres, as in supabase/tests): python3 scripts/staging/gen_private_photos_files.py
Then: sh supabase/tests/staging_private_photos_test.sh   (and CI checks that the committed files are up to date).
"""
import os, subprocess, sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOCK = os.environ.get("PGSOCK", "/var/tmp/pgc"); PORT = os.environ.get("PGPORT", "54329")
DB = "ct_gen_pp"
STAGING_ID = "7702070854497379551"
A, B, PREV = "20261105000000", "20261105010000", "20261104000000"
A_FILE, B_FILE = "20261105000000_private_photos", "20261105010000_private_photos_enforce"

# The state, as SQL expressions (identical in every generated file and in this generator).
EXPR = {
    "POL": "coalesce((select string_agg(format('%s|%s|%s|%s|%s|%s', policyname, cmd, permissive, roles::text, coalesce(qual, '-'), coalesce(with_check, '-')), E'\\n' order by policyname) from pg_catalog.pg_policies where schemaname = 'storage' and tablename = 'objects'), '')",
    "FN": "coalesce((select string_agg(format('%s|%s|%s|%s|anon=%s|authenticated=%s', p.proname, md5(p.prosrc), coalesce(array_to_string(p.proconfig, ','), '-'), p.prosecdef, has_function_privilege('anon', p.oid, 'execute'), has_function_privilege('authenticated', p.oid, 'execute')), E'\\n' order by p.proname) from pg_catalog.pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('admin_review', 'is_admin', 'submit_photo', 'admin_publish_photo', 'profile_insert_review', 'photo_publish_guard')), '')",
    "BKT": "coalesce((select string_agg(format('%s|%s|%s|%s', id, public, coalesce(file_size_limit::text, '-'), coalesce(array_to_string(allowed_mime_types, ','), '-')), E'\\n' order by id) from storage.buckets), '')",
    "TRG": "coalesce((select string_agg(format('%s|%s', tgrelid::regclass, tgname), E'\\n' order by tgrelid::regclass::text, tgname) from pg_catalog.pg_trigger where tgname in ('teachers_insert_review', 'institutes_insert_review', 'zz_photo_publish')), '')",
    "COL": "coalesce((select string_agg(x, ',' order by x) from (select 'profiles.avatar_path' x from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'avatar_path' union all select conname::text from pg_catalog.pg_constraint where conname = 'profiles_avatar_path_chk') s), '')",
}
LABEL = {"POL": "the policies on storage.objects", "FN": "the photo functions (body, search_path, definer, execute rights)",
         "BKT": "the storage buckets", "TRG": "the photo triggers", "COL": "profiles.avatar_path and its check"}


def psql(*args, db=DB, quiet=True):
    cmd = ["psql", "-h", SOCK, "-p", PORT, "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-At", "-d", db] + list(args)
    env = dict(os.environ, PGOPTIONS="-c client_min_messages=warning")
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        sys.exit(f"psql failed: {' '.join(args)[:200]}\n{r.stderr}")
    return r.stdout


def state():
    return {k: psql("-c", f"select {e}").rstrip("\n") for k, e in EXPR.items()}


def read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read()


def body_of_down(rel):
    """The rollback file without its comment header lines and its own begin/commit (as P0-1)."""
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
            "  if not (select relrowsecurity from pg_catalog.pg_class where oid = 'storage.objects'::regclass) then raise exception 'refusing: row level security is off on storage.objects'; end if;\n"
            "  if exists (select 1 from pg_catalog.pg_roles where rolname in ('anon', 'authenticated') and rolbypassrls) then raise exception 'refusing: anon or authenticated bypasses row level security'; end if;\n")


def newest(version, verb="guard"):
    word = "refusing" if verb == "guard" else "aborting"
    return (f"  if (select max(version) from supabase_migrations.schema_migrations) is distinct from '{version}' then raise exception '{word}: the newest recorded migration is not {version} (found %)', (select max(version) from supabase_migrations.schema_migrations); end if;\n"
            f"  if (select count(*) from supabase_migrations.schema_migrations where version = '{version}') <> 1 then raise exception '{word}: {version} is not recorded exactly once'; end if;\n")


def block(name, lines):
    return f"do ${name}$\ndeclare v text;\nbegin\n{lines}end ${name}$;\n"


def main():
    for t in ("psql",):
        if subprocess.run(["which", t], capture_output=True).returncode:
            sys.exit(f"{t} is required")
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
    psql("-f", os.path.join(REPO, f"supabase/rollback/{A_FILE}.down.sql")); s0k = state()
    if any(s0k[k] != s0[k] for k in ("POL", "FN", "TRG")):
        sys.exit("rolling A back does not give the policies, functions and triggers before A: fix the rollback first")
    psql("-c", f"drop database if exists {DB}", db="postgres")

    head = "-- GENERATED by scripts/staging/gen_private_photos_files.py from the committed migration and rollback files. Do not edit.\n"
    data_a = ("  if exists (select 1 from public.teachers where pending_changes ? 'photo_path') or exists (select 1 from public.institutes where pending_changes ? 'photo_path')\n"
              "    then raise exception 'refusing: a teacher or institute already has a waiting private photo (photo_path)'; end if;\n")

    # ---------- apply A ----------
    guard = identity()
    guard += f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{A}') then raise exception 'refusing: {A} is already recorded'; end if;\n"
    guard += newest(PREV)
    guard += check("POL", s0["POL"], "guard") + check("FN", s0["FN"], "guard") + check("TRG", s0["TRG"], "guard")
    guard += ("  -- the bucket and the column are absent, or kept (unused) by an earlier rollback of this step\n"
              f"  v := {EXPR['BKT']};\n"
              f"  if v is distinct from {dq(s0['BKT'])} and v is distinct from {dq(s0k['BKT'])} then raise exception E'refusing: the storage buckets are not the expected state. Found:\\n%', v; end if;\n"
              "  if exists (select 1 from storage.objects where bucket_id = 'photos-private') then raise exception 'refusing: the bucket photos-private already holds files'; end if;\n"
              f"  v := {EXPR['COL']};\n"
              f"  if v is distinct from {dq(s0['COL'])} and v is distinct from {dq(s0k['COL'])} then raise exception E'refusing: profiles.avatar_path and its check are not the expected state. Found:\\n%', v; end if;\n"
              "  if v <> '' then  -- the column exists (kept by a rollback): it must be unused; read dynamically, it may not exist\n"
              "    execute 'select count(*)::text from public.profiles where avatar_path is not null' into v;\n"
              "    if v <> '0' then raise exception 'refusing: profiles.avatar_path is already in use'; end if;\n"
              "  end if;\n")
    guard += data_a
    post = newest(A, "check") + "".join(check(k, s1[k], "check") for k in ("POL", "FN", "TRG", "BKT", "COL"))
    mig = read(f"supabase/migrations/{A_FILE}.sql")
    apply_a = (head +
               f"-- classi-staging ONLY: applies migration {A_FILE} (private photos, step A) in one transaction, recorded once.\n"
               "-- Run in Supabase -> project classi-staging -> SQL Editor, never through a workflow. Any error rolls everything back.\n"
               f"-- Refuses before any change unless: the classi-staging cluster id and marker; the newest migration is exactly {PREV};\n"
               "-- RLS on storage.objects with no bypass; the storage policies, the photo functions (body checksum, search_path, definer,\n"
               "-- execute rights) and triggers exactly as before step A; no waiting private photo; the private bucket and avatar_path\n"
               "-- absent or kept unused by an earlier rollback. Before commit it checks the full state after step A the same way.\n"
               "-- Order: this file, then the app code with the private flow, then the B file. Rollback: rollback_" + A_FILE + ".sql\n"
               "begin;\n" + block("guard", guard) +
               f"-- ===== BEGIN MIGRATION supabase/migrations/{A_FILE}.sql =====\n" + mig + "-- ===== END MIGRATION =====\n" +
               f"insert into supabase_migrations.schema_migrations (version, name) values ('{A}', 'private_photos');\n" +
               block("check", post) + "commit;\n-- expected result: \"Success. No rows returned\"\n")

    # ---------- rollback A ----------
    guard = identity() + newest(A)
    guard += f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{B}') then raise exception 'refusing: step B is recorded: roll it back first'; end if;\n"
    guard += "".join(check(k, s1[k], "guard") for k in ("POL", "FN", "TRG", "BKT", "COL"))
    guard += ("  -- nothing may be left that only step A can show or publish: decide (approve/reject) and clear it first\n"
              "  if exists (select 1 from public.teachers where pending_changes ? 'photo_path') or exists (select 1 from public.institutes where pending_changes ? 'photo_path')\n"
              "    then raise exception 'refusing: waiting private photos exist (approve or reject them first)'; end if;\n"
              "  if exists (select 1 from public.profiles where avatar_path is not null) then raise exception 'refusing: private profile photos are in use (profiles.avatar_path)'; end if;\n"
              "  if exists (select 1 from storage.objects where bucket_id = 'photos-private') then raise exception 'refusing: the bucket photos-private still holds files'; end if;\n")
    post = newest(PREV, "check") + "".join(check(k, s0k[k], "check") for k in ("POL", "FN", "TRG", "BKT", "COL"))
    rollback_a = (head +
                  f"-- classi-staging ONLY: rolls back {A_FILE} (step A) in ONE transaction: functions, policies, triggers,\n"
                  "-- admin_review and the migration record together. Run in Supabase -> classi-staging -> SQL Editor. Any error rolls\n"
                  f"-- everything back. Refuses unless: classi-staging; {A} is the newest migration (B not recorded); the full state is\n"
                  "-- exactly the one step A leaves; no waiting private photo, no private profile photo, no file in photos-private.\n"
                  "-- Kept on purpose (nothing lost): the empty bucket photos-private and the unused column profiles.avatar_path.\n"
                  "-- Before commit it checks that the state is the one before step A (plus those two).\n"
                  "begin;\n" + block("guard", guard) +
                  f"-- ===== BEGIN ROLLBACK supabase/rollback/{A_FILE}.down.sql =====\n" + body_of_down(f"supabase/rollback/{A_FILE}.down.sql") +
                  "-- ===== END ROLLBACK =====\n" +
                  f"delete from supabase_migrations.schema_migrations where version = '{A}';\n" +
                  block("check", post) + "commit;\n-- expected result: \"Success. No rows returned\"\n")

    # ---------- apply B ----------
    guard = identity()
    guard += f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{B}') then raise exception 'refusing: {B} is already recorded'; end if;\n"
    guard += newest(A)
    guard += ("  if not exists (select 1 from public.app_secrets where key = 'private_photos_app' and value = 'deployed')\n"
              "    then raise exception 'refusing: the app code with private photos is not marked as deployed (run mark_private_photos_app_deployed.sql after verifying the deployment)'; end if;\n")
    guard += "".join(check(k, s1[k], "guard") for k in ("POL", "FN", "TRG", "BKT", "COL"))
    post = newest(B, "check") + "".join(check(k, s2[k], "check") for k in ("POL", "FN", "TRG", "BKT", "COL"))
    apply_b = (head +
               f"-- classi-staging ONLY: applies migration {B_FILE} (private photos, step B: enforcement) in one transaction.\n"
               "-- Run in Supabase -> project classi-staging -> SQL Editor, never through a workflow. Any error rolls everything back.\n"
               f"-- Refuses unless: classi-staging; the newest migration is exactly {A} (step A); the app code with private photos is\n"
               "-- marked deployed (app_secrets private_photos_app = 'deployed', set by mark_private_photos_app_deployed.sql after the\n"
               "-- deployment was verified); the full state is exactly the one step A leaves. Before commit it checks the state after B.\n"
               "-- Rollback: rollback_" + B_FILE + ".sql\n"
               "begin;\n" + block("guard", guard) +
               f"-- ===== BEGIN MIGRATION supabase/migrations/{B_FILE}.sql =====\n" + read(f"supabase/migrations/{B_FILE}.sql") +
               "-- ===== END MIGRATION =====\n" +
               f"insert into supabase_migrations.schema_migrations (version, name) values ('{B}', 'private_photos_enforce');\n" +
               block("check", post) + "commit;\n-- expected result: \"Success. No rows returned\"\n")

    # ---------- rollback B ----------
    guard = identity() + newest(B) + "".join(check(k, s2[k], "guard") for k in ("POL", "FN", "TRG", "BKT", "COL"))
    post = newest(A, "check") + "".join(check(k, s1[k], "check") for k in ("POL", "FN", "TRG", "BKT", "COL"))
    rollback_b = (head +
                  f"-- classi-staging ONLY: rolls back {B_FILE} (step B) in ONE transaction: the user upload policies of the public\n"
                  "-- bucket come back, the photo-link guard goes, and the migration record goes, together. Run in Supabase -> classi-staging\n"
                  f"-- -> SQL Editor. Refuses unless: classi-staging; {B} is the newest migration; the full state is exactly the one step B\n"
                  "-- leaves. Before commit it checks that the state is exactly the one after step A. Roll B back BEFORE the app code.\n"
                  "begin;\n" + block("guard", guard) +
                  f"-- ===== BEGIN ROLLBACK supabase/rollback/{B_FILE}.down.sql =====\n" + body_of_down(f"supabase/rollback/{B_FILE}.down.sql") +
                  "-- ===== END ROLLBACK =====\n" +
                  f"delete from supabase_migrations.schema_migrations where version = '{B}';\n" +
                  block("check", post) + "commit;\n-- expected result: \"Success. No rows returned\"\n")

    # ---------- the "app deployed" marker ----------
    mark = (head +
            "-- classi-staging ONLY: records that the app code with private photos is deployed on classi-staging and verified, so\n"
            "-- that the B file may run. Run it ONLY after the deployment was checked (READY, no runtime errors, photo flow tested).\n"
            "begin;\n" + block("guard", identity() + newest(A) +
                               f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{B}') then raise exception 'refusing: step B is already recorded'; end if;\n") +
            "insert into public.app_secrets (key, value) values ('private_photos_app', 'deployed') on conflict (key) do update set value = excluded.value;\n"
            "commit;\n")
    unmark = (head +
              "-- classi-staging ONLY: removes the \"app with private photos deployed\" marker (before going back to the older app).\n"
              "-- Refuses while step B is recorded: roll B back first (an older app with B in place cannot upload photos).\n"
              "begin;\n" + block("guard", identity() +
                                 f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{B}') then raise exception 'refusing: step B is recorded: roll it back first'; end if;\n") +
              "delete from public.app_secrets where key = 'private_photos_app';\n"
              "commit;\n")

    out = {f"supabase/staging/apply_{A_FILE}.sql": apply_a, f"supabase/staging/rollback_{A_FILE}.sql": rollback_a,
           f"supabase/staging/apply_{B_FILE}.sql": apply_b, f"supabase/staging/rollback_{B_FILE}.sql": rollback_b,
           "supabase/staging/mark_private_photos_app_deployed.sql": mark,
           "supabase/staging/unmark_private_photos_app_deployed.sql": unmark}
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
