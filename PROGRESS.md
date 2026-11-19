# Classi v3 — PROGRESS

Branch: `v3/dev` (from `hardening/d08` at `7af7aef`). **Local only: not pushed, not merged, not deployed.**
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
| 3 | **Screens**: `/ledger` (owner and permitted staff: totals, 30-day report by method, overdue ageing, filters, new charge, payments, corrections, adjust/cancel, staff permissions, CSV export that cannot inject spreadsheet formulas); customer's read-only "مستحقاتي" on `/account` with the notice; admin trial/grace/launch settings, per-business state, extension, exemption, discount; owner trial/grace banner. | `5ee4896` |
| 4 | **Free security CI**: Gitleaks over the whole history (binary pinned to the release checksum), Semgrep CE (ERROR fails), CodeQL security-extended, dependency review on PRs, Dependabot config. CI and the scans also run on `v3/**`. `vercel.json` turns off Vercel deployments for `v3/**`, so a later push builds nothing. | `3577816` + this commit |
| 5 | **Rollback**: down files for both v3 migrations; `v3_rollback_test.sh` proves the schema after rollback is identical (functions, grants, settings, tables, columns) to the schema without v3. Added to CI. | `f0d3436` |

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

- **`next build`, full `tsc`, ESLint, Playwright E2E**: this workspace cannot reach the npm registry, so Next.js and
  its types are not installed. They run in GitHub Actions once the branch is pushed (pending approval, item 1).
- Semgrep and CodeQL run only in Actions.

## PENDING_APPROVAL

| # | Needs your decision | Why it waits |
|---|---|---|
| 1 | Push `v3/dev` to GitHub (CI + security scans run; Vercel builds nothing for `v3/**`) | First full build and E2E of the new screens |
| 2 | Apply the two v3 migrations to **Staging** (SQL Editor, guarded files to be generated like D-08's) | Changes a hosted database |
| 3 | D-08 Migration B on Staging | Separate approval; the probe marker expires 20/11 19:14 (Jerusalem), so a new probe is needed first |
| 4 | Prices (proposal in the plan, section 4), trial 30 days, grace 7 days, the launch date, and when to turn on `subscriptions_required` | Business decisions |
| 5 | GitHub settings: ruleset on `main` (PR + required checks), Dependabot alerts and security updates, CodeQL advanced setup | Security settings |
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
