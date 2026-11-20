#!/usr/bin/env python3
"""Generates the guarded PRODUCTION files for the 12 migrations production does not have yet (prepared, never applied
by this script; each needs the owner's approval). Model of the staging files, with a FULL-schema guard:

  supabase/production/apply_<NN>_<migration>.sql      NN = 01..12, in order
  supabase/production/rollback_<NN>_<migration>.sql   when supabase/rollback/<migration>.down.sql exists
  supabase/production/mark_private_photos_app_deployed.sql / unmark_…   (gate of step 10, as on staging)

Every file is one transaction that refuses to run unless: the cluster is Classi production's; the marker says
production; the tracking table holds exactly the migrations before this step (and not this one); the public schema,
storage policies/buckets and app_private functions have EXACTLY the fingerprint this step expects (computed here by
building production's schema locally from main's 25 migrations, then each migration in turn); no public role bypasses
RLS; plus the step's own gate (step 10: the private-photos app code is marked deployed; step 12: the D-08 dispatch
code handled a wake-up with the server key in the last 24 hours). After the change, and before COMMIT, it checks
that the fingerprint is the one this step must produce and that the step is recorded. A rollback checks the reverse.

The generator itself proves on the local build that each rollback returns the exact fingerprint before its step and
that re-applying gives the same result again. Usage: python3 scripts/production/gen_production_files.py
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from fpexpr import FP  # noqa: E402

SOCK = os.environ.get("PGSOCK", "/var/tmp/pgc"); PORT = os.environ.get("PGPORT", "54329")
# Local test server only: PGSOCK is a plain absolute socket directory or a loopback host, PGPORT a number. They reach
# psql as list arguments, never through a shell.
if not (re.fullmatch(r"/[A-Za-z0-9_./-]{1,200}", SOCK) and ".." not in SOCK or SOCK in ("127.0.0.1", "localhost", "::1")) \
        or not re.fullmatch(r"\d{2,5}", PORT):
    sys.exit("PGSOCK must be an absolute socket directory or a loopback host, and PGPORT a port number")
DB = "ct_gen_prod"
CLUSTER = "7692130048193495360"
BASE = "20261027020000"           # production today (main): 25 migrations
STOP = "20261120000000"           # v3 is not part of this launch
MIG = os.path.join(REPO, "supabase", "migrations")
RB = os.path.join(REPO, "supabase", "rollback")
OUT = os.path.join(REPO, "supabase", "production")

ALL = sorted(f[:-4] for f in os.listdir(MIG) if f.endswith(".sql"))
DONE = [m for m in ALL if m[:14] <= BASE]
STEPS = [m for m in ALL if BASE < m[:14] < STOP]
if len(DONE) != 25 or len(STEPS) != 12:
    sys.exit(f"expected 25 applied and 12 pending migrations, found {len(DONE)} and {len(STEPS)}")

GATES = {
    "20261105010000": ("the app code with private photos is marked deployed",
                       "  if (select value from public.app_secrets where key = 'private_photos_app') is distinct from 'deployed' then\n"
                       "    raise exception 'refusing: the app code with private photos is not marked as deployed (run mark_private_photos_app_deployed.sql after checking the deployment)';\n"
                       "  end if;\n"),
    "20261114010000": ("the D-08 dispatch code handled a wake-up with the server key in the last 24 hours",
                       "  if not exists (select 1 from public.app_secrets where key = 'd08_worker_seen_at' and value::timestamptz > now() - interval '24 hours') then\n"
                       "    raise exception 'refusing: the new dispatch code has not handled a wake-up with the server key in the last 24 hours (app_secrets d08_worker_seen_at): deploy it with SUPABASE_SERVICE_ROLE_KEY and let one wake-up happen first';\n"
                       "  end if;\n"),
}
# A rollback that intentionally does NOT return to the exact earlier state: the files guard on the state it really gives
# (proved here), and say so. Re-applying such a step after its rollback needs regenerated files.
RESIDUE = {
    "20261031010000": "teachers.hours_confirmed_at is kept and bookings_zzz_rules keeps the rule_teacher_hours switch (the emergency off-switch for the hours rule)",
    "20261031020000": "replace_availability keeps the phase 3 body: the phase 2 body fails on Supabase (pg_safeupdate)",
    "20261103010000": "my_review_state() is kept: it returns only the caller's own rows and the new app needs it",
    "20261105000000": "the bucket photos-private and the column profiles.avatar_path are kept, so no file or data is lost",
}
NOTES = {
    "20261103010000": "The CURRENT production code breaks after this step (/teach and /manage/course read pending_changes and "
                      "review_note): run it in the maintenance window, then deploy the new code right away.",
    "20261105010000": "Only after the new code is deployed and checked (uploads go to the private bucket).",
    "20261114000000": "D-08 A. Then set SUPABASE_SERVICE_ROLE_KEY in Vercel and let one wake-up happen before step 12.",
    "20261114010000": "D-08 B: only after step 11, the deployment and a wake-up within 24 hours.",
}


def psql(*args, db=DB, check=True):
    cmd = ["psql", "-h", SOCK, "-p", PORT, "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-At", "-d", db] + list(args)
    # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args -- list argv, no shell, PGSOCK/PGPORT validated above, local test server only
    r = subprocess.run(cmd, capture_output=True, text=True, env=dict(os.environ, PGOPTIONS="-c client_min_messages=warning"))
    if check and r.returncode != 0:
        sys.exit(f"psql failed: {' '.join(args)[:200]}\n{r.stderr}")
    return r.stdout


def fp():
    return psql("-c", f"select {FP}").rstrip("\n")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


TXN = re.compile(r"(?im)^\s*(begin|commit)\s*;\s*$")


def rb_body(path):
    """A rollback file without its own top-level begin;/commit; lines (the production file is one transaction)."""
    body = TXN.sub("", read(path)).rstrip() + "\n"
    if re.search(r"(?im)^\s*(begin|commit|rollback|start\s+transaction)\b\s*;", body) or re.search(r"(?im)^\s*\\", body):
        sys.exit(f"{os.path.basename(path)}: transaction control or a psql meta-command that cannot be wrapped")
    return body


def rb_body_file(path):
    fd, tmp = tempfile.mkstemp(prefix="gen_prod_", suffix=".sql")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("begin;\n" + rb_body(path) + "commit;\n")
    return tmp


# 1. production's schema, locally: stub + main's 25 migrations; must equal the fingerprint recorded on 20/11
psql("-c", f"drop database if exists {DB}", "-c", f"create database {DB}", db="postgres")
psql("-f", os.path.join(REPO, "supabase", "tests", "supabase_stub.sql"))
for m in DONE:
    psql("-f", os.path.join(MIG, m + ".sql"))
expected_base = read(os.path.join(HERE, f"expected_{BASE}.txt")).strip()
if fp() != expected_base:
    sys.exit("the local build of main's 25 migrations is not production's recorded fingerprint")

# 2. each step: fingerprint before/after; rollback must return exactly to "before", and re-applying to "after"
before, after, rolled = {}, {}, {}
for m in STEPS:
    before[m] = fp()
    psql("-f", os.path.join(MIG, m + ".sql"))
    after[m] = fp()
    if after[m] == before[m]:
        sys.exit(f"{m} changes nothing the fingerprint sees: extend scripts/production/fingerprint.sql")
    down = os.path.join(RB, m + ".down.sql")
    if os.path.exists(down):
        psql("-f", rb_body_file(down))
        rolled[m] = fp()
        if rolled[m] != before[m] and m[:14] not in RESIDUE:
            sys.exit(f"rolling {m} back does not give the exact state before it: fix the rollback first")
        if rolled[m] == before[m] and m[:14] in RESIDUE:
            sys.exit(f"{m}: the rollback is exact now; remove it from RESIDUE")
        psql("-f", os.path.join(MIG, m + ".sql"))
        if fp() != after[m]:
            sys.exit(f"re-applying {m} after its rollback does not give the same state")
# 3. the whole chain back: from step 12 down to step 2, each rollback starting from what the previous one left
chain_before, chain_after = {}, {}
for m in reversed(STEPS):
    down = os.path.join(RB, m + ".down.sql")
    if not os.path.exists(down):
        break
    chain_before[m] = fp()
    psql("-f", rb_body_file(down))
    chain_after[m] = fp()
# Re-applying after a rollback of SEVERAL steps is not covered by these files: the documented residues stay, so the
# first re-applied step would see a different schema and refuse. Regenerate the files from that state first.
psql("-c", f"drop database if exists {DB}", db="postgres")


def fp_check(stage, fingerprint, alt=None, path_set=False, path_expect=None):
    """The fingerprint must be `fingerprint` (or `alt`). path_set: remember which one it was (rollbacks: 'direct' or
    'chain'); path_expect: {'direct': fp, 'chain': fp} = what this point must be, given the remembered path."""
    if path_expect:
        d, c = path_expect["direct"], path_expect["chain"]
        return (f"  v_fp := {FP};\n"
                f"  if v_fp is distinct from (case current_setting('classi.rb_path', true) when 'chain' then $c${c}$c$ else $d${d}$d$ end) then\n"
                f"    raise exception 'refusing ({stage}): the schema is not the expected one at this point: %', v_fp;\n  end if;\n")
    cond = f"v_fp is distinct from $exp${fingerprint}$exp$" + (f" and v_fp is distinct from $alt${alt}$alt$" if alt and alt != fingerprint else "")
    out = (f"  v_fp := {FP};\n"
           f"  if {cond} then\n"
           f"    raise exception 'refusing ({stage}): the schema is not the expected one at this point: %', v_fp;\n  end if;\n")
    if path_set:
        out += f"  perform set_config('classi.rb_path', case when v_fp = $exp${fingerprint}$exp$ then 'direct' else 'chain' end, true);\n"
    return out


def guard(stage, fingerprint, newest, count, absent=None, present=None, gate="", alt=None, path_set=False, path_expect=None):
    checks = [
        f"  if (select system_identifier::text from pg_control_system()) is distinct from '{CLUSTER}' then\n"
        f"    raise exception 'refusing ({stage}): this is not the Classi production database';\n  end if;\n",
        "  if (select value from public.app_secrets where key = 'deploy_env') is distinct from 'production' then\n"
        f"    raise exception 'refusing ({stage}): the database is not marked production (run apply_0_tracking.sql first)';\n  end if;\n",
        "  if to_regclass('supabase_migrations.schema_migrations') is null then\n"
        f"    raise exception 'refusing ({stage}): no migration tracking (run apply_0_tracking.sql first)';\n  end if;\n",
        f"  if (select max(version) from supabase_migrations.schema_migrations) is distinct from '{newest}'\n"
        f"     or (select count(*) from supabase_migrations.schema_migrations) <> {count} then\n"
        f"    raise exception 'refusing ({stage}): the newest recorded migration must be {newest} with {count} recorded (found % with %)',\n"
        "      (select max(version) from supabase_migrations.schema_migrations), (select count(*) from supabase_migrations.schema_migrations);\n  end if;\n",
    ]
    if absent:
        checks.append(f"  if exists (select 1 from supabase_migrations.schema_migrations where version = '{absent}') then\n"
                      f"    raise exception 'refusing ({stage}): {absent} is already recorded';\n  end if;\n")
    if present:
        checks.append(f"  if (select count(*) from supabase_migrations.schema_migrations where version = '{present}') <> 1 then\n"
                      f"    raise exception 'refusing ({stage}): {present} is not recorded exactly once';\n  end if;\n")
    checks.append("  if exists (select 1 from pg_roles where rolname in ('anon', 'authenticated') and rolbypassrls) then\n"
                  f"    raise exception 'refusing ({stage}): anon or authenticated bypasses row level security';\n  end if;\n")
    checks.append(gate)
    checks.append(fp_check(stage, fingerprint, alt, path_set, path_expect))
    return "do $guard$\ndeclare v_fp text;\nbegin\n" + "".join(checks) + "end $guard$;\n"


HEAD = ("-- GENERATED by scripts/production/gen_production_files.py from the committed migrations. Do not edit by hand.\n"
        "-- Classi PRODUCTION, {what}. Run ONCE in the Supabase SQL Editor of the production project, only with the owner's\n"
        "-- approval, after a backup proven by restore. One transaction: any refusal or error changes nothing.\n")
os.makedirs(OUT, exist_ok=True)
for name in os.listdir(OUT):
    if re.fullmatch(r"(apply|rollback)_\d\d_.*\.sql|(un)?mark_private_photos_app_deployed\.sql", name):
        os.remove(os.path.join(OUT, name))
written = []
prev = BASE
for i, m in enumerate(STEPS, 1):
    v = m[:14]; nn = f"{i:02d}"
    gate_label, gate_sql = GATES.get(v, ("", ""))
    note = NOTES.get(v, "The current production code keeps working after this step.")
    body = read(os.path.join(MIG, m + ".sql")).rstrip() + "\n"
    if re.search(r"(?im)^\s*(begin|commit|rollback)\s*;", body) or re.search(r"(?im)^\s*\\", body):
        sys.exit(f"{m} has its own transaction control or a psql meta-command: it cannot be wrapped")
    apply_sql = (HEAD.format(what=f"step {nn} of 12: {m}") +
                 f"-- {note}\n" + (f"-- Gate: {gate_label}.\n" if gate_label else "") +
                 "begin;\nset local lock_timeout = '5s';\nset local statement_timeout = '120s';\n" +
                 guard("before", before[m], prev, 25 + i - 1, absent=v, gate=gate_sql, alt=rolled.get(m)) +
                 f"\n-- ===== {m}.sql (verbatim) =====\n{body}-- ===== end of {m}.sql =====\n\n" +
                 f"insert into supabase_migrations.schema_migrations (version, name) values ('{v}', '{m}');\n" +
                 guard("before commit", after[m], v, 25 + i, present=v) + "commit;\n")
    path = os.path.join(OUT, f"apply_{nn}_{m}.sql")
    with open(path, "w", encoding="utf-8") as f:
        f.write(apply_sql)
    written.append(path)
    down = os.path.join(RB, m + ".down.sql")
    if os.path.exists(down):
        rb = rb_body(down)
        residue = RESIDUE.get(v)
        rollback_sql = (HEAD.format(what=f"ROLLBACK of step {nn}: {m}") +
                        (f"-- Not exact on purpose: {residue}. Guarded on the state it really gives.\n" if residue else "") +
                        "begin;\nset local lock_timeout = '5s';\nset local statement_timeout = '120s';\n" +
                        guard("before", after[m], v, 25 + i, present=v, alt=chain_before.get(m), path_set=True) +
                        f"\n-- ===== {m}.down.sql (verbatim) =====\n{rb}-- ===== end =====\n\n" +
                        f"delete from supabase_migrations.schema_migrations where version = '{v}';\n" +
                        guard("before commit", rolled[m], prev, 25 + i - 1, absent=v,
                              path_expect={"direct": rolled[m], "chain": chain_after.get(m, rolled[m])}) + "commit;\n")
        path = os.path.join(OUT, f"rollback_{nn}_{m}.sql")
        with open(path, "w", encoding="utf-8") as f:
            f.write(rollback_sql)
        written.append(path)
    prev = v

# the gate of step 10, as on staging: recorded only after the deployment was checked
pp_prev = "20261105000000"
for name, value, what in (("mark_private_photos_app_deployed.sql", "insert into public.app_secrets (key, value) values ('private_photos_app', 'deployed') on conflict (key) do update set value = excluded.value;\n",
                           "records that the app code with private photos is deployed and checked (gate of step 10)"),
                          ("unmark_private_photos_app_deployed.sql", "delete from public.app_secrets where key = 'private_photos_app';\n",
                           "removes that record")):
    i = STEPS.index(next(m for m in STEPS if m.startswith(pp_prev))) + 1
    text = (HEAD.format(what=what) + "begin;\n" +
            guard("before", after[STEPS[i - 1]], pp_prev, 25 + i, present=pp_prev).replace("$guard$", "$g$") +
            value + "commit;\n")
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    written.append(path)

for p in written:
    print("wrote", os.path.relpath(p, REPO))
