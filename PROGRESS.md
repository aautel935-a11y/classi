# Classi v3 — PROGRESS

Branch: `v3/dev` (from `hardening/d08` at `7af7aef`). **Pushed to GitHub on 19/11 with the owner's approval; not merged, not deployed.**
Vercel: `vercel.json` turns off deployments for `v3/**`; checked afterwards: no deployment exists for `v3/dev` in either project.
Nothing was changed in Production, Staging, `main`, their databases, Vercel, GitHub settings or secrets.
D-08 Migration B was not run. No real customer data was used: every test runs on throw-away local Postgres 16
databases with synthetic accounts.

Plan: [Classi v3 — الخطة الموحدة](https://claude.ai/artifact/VnmWqU8jjeUzhSDEhGSefR) · security audit:
[تحصين أمني بلا تكلفة إضافية](https://claude.ai/artifact/H148tF81xjLzzRq4whGNCv).

## Done

| # | What | Commit |
|---|---|---|
| 1 | **Customer payments ledger** (decision 19/11): charges linked to a booking or entered by hand; deposit, partial and multiple payments, refunds; status computed (unpaid / partial / paid / overdue / cancelled); method, date, note and who recorded it. Payments and audit log are **append-only** (a trigger refuses UPDATE/DELETE even for the service role); corrections are documented void entries with a reason. Institute staff need an explicit permission (record / correct / reports). Notes refuse card-like numbers (Luhn). No gateway, no card data, no tax documents. | `7c33257` |
| 2 | **Business access**: 30-day trial (from launch date for existing businesses, from creation after launch), grace period, exemptions, discounts on open requests (list price kept), editable plans, reminders 7/3/1 days before the end and during grace, admin report of recorded revenue. Repeat trials (same owner or same phone, stored only as a SHA-256 hash) get no free days until an admin checks and extends. **Nothing is deleted when access ends**; nothing changes until the admin turns on the existing `subscriptions_required` switch. | `f0d3436` |
| 3 | **Screens** (plus a "record a partial payment" link from each open booking): `/ledger` (owner and permitted staff: totals, 30-day report by method, overdue ageing, filters, new charge, payments, corrections, adjust/cancel, staff permissions, CSV export that cannot inject spreadsheet formulas); customer's read-only "مستحقاتي" on `/account` with the notice; admin trial/grace/launch settings, per-business state, extension, exemption, discount; owner trial/grace banner. | `5ee4896` |
| 4 | **Free security CI**: Gitleaks over the whole history (binary pinned to the release checksum), Semgrep CE (ERROR fails), CodeQL security-extended, dependency review on PRs, Dependabot config. CI and the scans also run on `v3/**`. `vercel.json` turns off Vercel deployments for `v3/**`, so a later push builds nothing. | `3577816` + this commit |
| 5 | **Rollback**: down files for both v3 migrations; `v3_rollback_test.sh` proves the schema after rollback is identical (functions, grants, settings, tables, columns) to the schema without v3. Added to CI. | `f0d3436` |

## CI on GitHub (19/11/2026, commit `549998c`)

| Job | Result | Run |
|---|---|---|
| quality: npm ci, npm audit, TypeScript, ESLint, unit tests, guards, `next build` | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44613829890/job/135877066377) |
| database: all 32 SQL suites, RPC grants, rollback drills, v3 rollback exactness | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44613829890/job/135877066346) |
| staging files on PostgreSQL 17 | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44613829890/job/135877066353) |
| e2e: Playwright on a local Supabase stack (37 passed, 5 skipped as before), incl. the new ledger journey on phone and desktop; backup/restore drill | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44613829890/job/135877065784) |
| Gitleaks, whole history | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44613829874/job/135877066511) |
| Semgrep CE (ERROR blocks) | PASS (10 warnings: actions pinned by tag, not SHA) | [job](https://github.com/aautel935-a11y/classi/actions/runs/44613829874/job/135877066101) |
| CodeQL security-extended | PASS (alerts list not readable from here) | [job](https://github.com/aautel935-a11y/classi/actions/runs/44613829874/job/135877066578) |

Fixed on the way (all in `v3/dev`): ledger E2E locator; Semgrep install (now the pinned official image) and readable
annotations; two Semgrep ERROR findings in the staging-file generators (input validation); `payments.voids` foreign key
deferrable (backup drill warning); two permission tightenings (below).

Permission review (after the first push): a charge may be linked to a customer's account only if that customer booked
or bought a package from the business; refunds need the owner or `payments.correct`. Both covered by `ledger_test`
(100 checks).

## Round 2 — E2E for subscriptions, staff and isolation (20/11/2026, code commit `06feee0`)

| Job | Result | Run |
|---|---|---|
| quality: npm audit, TypeScript, ESLint, unit tests, guards, `next build` | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44623715051/job/135911849511) |
| database: 32 SQL suites, RPC grants, rollback drills, v3 rollback exactness | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44623715051/job/135911849523) |
| staging files on PostgreSQL 17 | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44623715051/job/135911849555) |
| e2e: **41 passed**, 5 skipped (by design, below) | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44623715051/job/135911848860) |
| Gitleaks | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44623714948/job/135911850722) |
| Semgrep CE | PASS | [job](https://github.com/aautel935-a11y/classi/actions/runs/44623714948/job/135911851144) |
| CodeQL v4, security-extended | PASS, 1 result (false positive, below) | [job](https://github.com/aautel935-a11y/classi/actions/runs/44623714948/job/135911851269) |

New E2E (both phone and desktop):
- `subscriptions.spec.mjs` — admin: trial 14 days, grace 5 days, launch date; trial extended (+10, audited); exemption
  granted then revoked; discount 170 → 120 with reason; renewal confirmed. Non-admin: `/admin` refused and
  `admin_set_setting`, `admin_extend_trial`, `admin_set_exemption`, `admin_upsert_plan` refused at the database with
  their own session. Owner: "14 days left", warning style and "3 days left" near the end, the reminder in
  notifications, grace (still public), expiry (public page 404, dashboard and profile kept), renewal (public again).
- `staff.spec.mjs` — booking → ledger → deposit; staff without permission: nothing visible, refused at the database;
  owner grants "record": staff records and corrects only their own entry; correcting the owner's entry, adjust, cancel,
  refund, report, export and self-granting refused; another institute: nothing visible, export 403, cannot write, cannot
  charge this institute's customer; the customer sees her charge with the notice, an unrelated customer nothing;
  revoking takes effect at once.

Skipped tests (5, all by design, unchanged): `d08.spec.mjs` ×3 on the phone project (database-state tests, run once on
desktop) and `forced-dark.spec.mjs` ×2 on the desktop project (they launch their own browsers, run once on the phone
project). The staging dry run's S1 is skipped because it checks a staging build, not the local build.

Semgrep warnings (10 at the first run): 10 × "action pinned by tag" in `ci.yml`/`security.yml` → **fixed** (pinned
to commit SHAs). Remaining: 2 of the same in `staging.yml` (left untouched: it is the owner-approved staging workflow)
and 8 parser notices (shell scripts, one TypeScript `satisfies`), not findings.

CodeQL: `js/user-controlled-bypass` at `app/auth/confirm/route.ts` — **false positive**: the guarded action is the
token verification itself (done by Supabase); the route now also accepts only Classi's link types and a well-formed
token. The action was upgraded to v4 (v3 is deprecated in December 2026).
Dependabot alerts: **disabled** for the repository (GitHub answer); enabling them is a settings change → owner.

## Files

New: `supabase/migrations/20261120000000_v3_ledger.sql`, `supabase/migrations/20261120010000_v3_business_access.sql`,
`supabase/rollback/2026112000*_v3_*.down.sql`, `supabase/tests/ledger_test.sql`, `supabase/tests/access_test.sql`,
`supabase/tests/v3_rollback_test.sh`, `lib/ledger.ts`, `tests/unit/ledger.test.mjs`, `app/ledger/page.tsx`,
`app/ledger/actions.ts`, `app/ledger/export/route.ts`, `app/admin/access-actions.ts`, `components/AccessAdmin.tsx`,
`components/AccessBanner.tsx`, `components/MyCharges.tsx`, `.github/workflows/security.yml`, `.github/dependabot.yml`,
`.gitleaksignore`, `PROGRESS.md`.

Changed: `app/account/page.tsx`, `app/admin/page.tsx`, `app/teach/page.tsx`, `app/manage/page.tsx`, `app/globals.css`
(one `.col` rule), `.github/workflows/ci.yml` (v3 branches, two rollback steps), `tests/run-unit.sh`,
`supabase/tests/expected_errors.txt`, `vercel.json` (`v3/**` not deployed).

Existing functions re-created (compared against their latest definitions): `owner_has_access` (same result while the
switch is off), `admin_set_setting` (the phase-3 version plus `trial_days`, `grace_days`, `launch_at`, now audited),
`subscription_reminders` (trial and grace added).

## Test results (local, 19/11/2026)

| Check | Result |
|---|---|
| All SQL suites (`run_all.sh`, 32 suites incl. the 2 new) | 32/32 ok |
| `ledger_test` | 96 checks PASS, 0 FAIL — isolation between businesses, customer read-only, staff permissions, append-only, corrections |
| `access_test` | 59 checks PASS, 0 FAIL — trial, repeat guard, grace, expiry hides but keeps data, exemption, discount, reminders, report |
| RPC grants (`check_rpc_grants.sh`) | PASS: all 114 RPCs the app calls are granted; 6 worker RPCs service-role only |
| D-08 worker-key guard, embeds guard, safe-update guard | ok |
| Unit tests (`tests/run-unit.sh`) | 92/92 |
| v3 rollback exactness + rollback drills (5 suites after rollback) | PASS |
| Gitleaks, whole history and working tree | 0 findings (1 known false positive listed) |
| TypeScript of the new files | clean against minimal stubs (see limits) |

## Not verified here (needs the owner or CI)

- Now verified in GitHub Actions, including the admin access screens, the owner's trial banner and the staff toggles.
- CodeQL alerts and Dependabot alerts cannot be listed from this workspace (GitHub blocks those API paths here).

## PENDING_APPROVAL

| # | Needs your decision | Why it waits |
|---|---|---|
| 1 | ~~Push `v3/dev`~~ done 19/11 with approval; CI green | — |
| 2 | Apply the two v3 migrations to **Staging**: plan in `docs/v3/STAGING_PLAN.md` (backup, guarded files, verify, rollback) | Changes a hosted database |
| 3 | D-08 Migration B on Staging | Separate approval; the probe marker expires 20/11 19:14 (Jerusalem), so a new probe is needed first |
| 4 | Prices (proposal in the plan, section 4), trial 30 days, grace 7 days, the launch date, and when to turn on `subscriptions_required` | Business decisions |
| 5 | GitHub settings: ruleset on `main` (PR + required checks), **Dependabot alerts (currently disabled)** and security updates, CodeQL advanced setup, dismissing the CodeQL false positive | Security settings |
| 6 | Supabase Auth: leaked-password protection (HIBP), TOTP MFA for admin accounts | Security settings |
| 7 | Encrypted off-site backup job: a read-only database role and its secret in a protected GitHub Environment, created by you | Needs a secret and a new role |
| 8 | Wording of the customer notice; legal review before any official tax document | Legal |
| 9 | Moving existing `pay_status` history into the ledger (a later, separate migration) and ledger retention when an account is deleted | Data decisions |
| 10 | Production: everything above, in the same order, after Staging | Production |

## Remaining risks and limits

- The ledger is what the business says it received; it is not bank proof (stated on every screen and export).
- Repeat-trial detection uses owner account and phone; a new phone and a new account can still start a new trial.
- `/ledger` and the admin screens were type-checked, not rendered: expect small layout fixes after the first CI build.
- Production is still behind Staging (P0-1 private photos and D-08 not applied there); see the security plan.
