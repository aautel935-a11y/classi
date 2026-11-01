import pg from "pg";
import { readFileSync } from "node:fs";
import { expect } from "@playwright/test";

const url = process.env.E2E_DB_URL || "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
// The local stack, or the STAGING project when E2E_TARGET=staging. Never the production project.
if (url.includes("rfxhqcagdsuhkjzwbawx")) throw new Error("E2E_DB_URL is the production project");
const STAGING = process.env.E2E_TARGET === "staging";
if (/supabase\.(co|com)/.test(url) && !STAGING) throw new Error("E2E_DB_URL must be the local test database (or set E2E_TARGET=staging)");
if (STAGING && !url.includes("nfipmylyahhogykikuqo")) throw new Error("E2E_TARGET=staging needs the classi-staging database (nfipmylyahhogykikuqo)");
// Staging runs as the least-privilege role e2e_staging (only the e2e.* functions), never as postgres.
if (STAGING && !/^postgres(ql)?:\/\/e2e_staging\./.test(url)) throw new Error("staging tests must connect as e2e_staging (STAGING_E2E_DB_URL), not postgres");
// Staging TLS: verified against Supabase's CA when its certificate is provided (PGSSLROOTCERT, set by the workflow
// from the SUPABASE_CA_CERT variable); otherwise encrypted without verification, and the workflow warns.
const ssl = !STAGING ? {} : process.env.PGSSLROOTCERT
  ? { ssl: { ca: readFileSync(process.env.PGSSLROOTCERT, "utf8"), rejectUnauthorized: true } }
  : { ssl: { rejectUnauthorized: false } };

/** One query (local test database; on staging only the e2e.* helper functions are callable). */
async function sql(text, params = []) {
  const c = new pg.Client({ connectionString: url, ...ssl });
  await c.connect();
  try { return (await c.query(text, params)).rows; } finally { await c.end(); }
}
const one = async (text, params) => (await sql(text, params))[0] ?? {};

/** Everything the tests read or do in the database. Locally plain SQL on the test stack; on staging the
 * least-privilege role e2e_staging calls the e2e.* functions (supabase/staging/e2e_role.sql), which act only
 * on the test's own accounts. */
export const db = STAGING ? {
  otp: async (digits) => (await one("select e2e.otp($1) as v", [digits])).v,
  otpCount: async (digits) => (await one("select e2e.otp_count($1) as v", [digits])).v,
  userId: async (digits) => (await one("select e2e.user_id($1) as v", [digits])).v,
  teacherId: async (user) => (await one("select e2e.teacher_id($1) as v", [user])).v,
  latestOffer: async (teacher) => (await one("select e2e.latest_offer($1) as v", [teacher])).v,
  offerBookings: (offer) => sql("select status, for_child from e2e.offer_bookings($1)", [offer]),
  unread: async (user) => Number((await one("select e2e.unread_count($1) as v", [user])).v),
  verifyTeacher: (teacher) => sql("select e2e.verify_teacher($1)", [teacher]),
  approveOffer: (offer) => sql("select e2e.approve_offer($1)", [offer]),
  makeAdmin: (user) => sql("select e2e.make_admin($1)", [user]),
  publicOffer: async (approvedOnly) => (await one("select e2e.public_offer($1) as v", [approvedOnly])).v,
  demoTeacher: async () => (await one("select e2e.demo_teacher() as v")).v,
  setDemoBio: (teacher, bio) => sql("select e2e.set_demo_bio($1, $2)", [teacher, bio]),
} : {
  otp: async (digits) => (await one("select otp as v from otp_outbox where regexp_replace(phone, '\\D', '', 'g') = $1 order by created_at desc limit 1", [digits])).v,
  otpCount: async (digits) => (await one("select count(*)::int as v from otp_outbox where regexp_replace(phone, '\\D', '', 'g') = $1", [digits])).v,
  userId: async (digits) => (await one("select id as v from auth.users where phone in ($1, '+' || $1) limit 1", [digits])).v,
  teacherId: async (user) => (await one("select id as v from teachers where user_id = $1", [user])).v,
  latestOffer: async (teacher) => (await one("select id as v from offerings where teacher_id = $1 order by created_at desc limit 1", [teacher])).v,
  offerBookings: (offer) => sql("select status::text, child_id is not null as for_child from bookings where offering_id = $1 order by created_at", [offer]),
  unread: async (user) => Number((await one("select count(*) as v from notifications where user_id = $1 and read_at is null", [user])).v),
  verifyTeacher: (teacher) => sql("update teachers set verify = 'verified' where id = $1", [teacher]),
  approveOffer: (offer) => sql("update offerings set review_status = 'approved' where id = $1", [offer]),
  makeAdmin: (user) => sql("update profiles set roles = array['admin']::app_role[] where id = $1", [user]),
  publicOffer: async (approvedOnly) => (await one("select id as v from offerings where type = 'private' and active and (not $1 or review_status = 'approved') order by created_at limit 1", [approvedOnly])).v,
  demoTeacher: async () => (await one("select id as v from teachers where verify = 'verified' and user_id is null order by name limit 1")).v,
  setDemoBio: (teacher, bio) => sql("update teachers set bio = $1 where id = $2 and user_id is null", [bio, teacher]),
};

/** A unique Israeli mobile for this project and role: 0521xxxxxx (mobile project) / 0522xxxxxx (desktop). */
export function phoneFor(testInfo, n) {
  const p = testInfo.project.name === "mobile" ? "1" : "2";
  const run = String(Date.now()).slice(-4);
  return `052${p}${run}${String(n).padStart(2, "0")}`.slice(0, 10);
}

async function readCode(phone) {
  const digits = "972" + phone.slice(1);
  for (let i = 0; i < 30; i++) {
    const otp = await db.otp(digits);
    if (otp) return otp;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`no sign-in code for ${phone}`);
}

/** Sign up with phone + code through the real login screen. */
const lastAuth = new WeakMap();
function watchAuth(page) {
  if (lastAuth.has(page)) return;
  lastAuth.set(page, "");
  page.on("response", async (r) => {
    if (r.url().includes("/auth/v1/")) lastAuth.set(page, `${r.request().method()} ${new URL(r.url()).pathname} -> ${r.status()} ${(await r.text().catch(() => "")).slice(0, 300)}`);
  });
  page.on("requestfailed", (r) => { if (r.url().includes("/auth/v1/")) lastAuth.set(page, `${r.url()} failed: ${r.failure()?.errorText}`); });
}

async function waitForCodeStep(page, phone) {
  const heading = page.getByRole("heading", { name: "أدخل الرمز" });
  const err = page.locator(".err");
  await expect(heading.or(err).first()).toBeVisible({ timeout: 20_000 });
  if (await err.isVisible()) {
    const outbox = await db.otpCount("972" + phone.slice(1));
    throw new Error(`code request refused on screen: "${(await err.textContent())?.trim()}" (otp_outbox rows: ${outbox}; last auth call: ${lastAuth.get(page)})`);
  }
}

export async function signUp(page, { phone, name, role }) {
  watchAuth(page);
  await page.goto("/login?mode=up");
  await page.locator("#full_name").fill(name);
  await page.locator(`input[name="role"][value="${role}"]`).check();
  await page.locator("#phone").fill(phone);
  if (role === "student") await page.locator('input[name="guardian_ok"]').check();
  await page.locator('input[name="terms"]').check();
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await waitForCodeStep(page, phone);
  await page.locator("#code").fill(await readCode(phone));
  await page.waitForURL((u) => !u.pathname.startsWith("/login"), { timeout: 20_000 });
  await page.waitForLoadState("networkidle"); // the sign-in page may still be redirecting
  return db.userId("972" + phone.slice(1));
}

/** Sign in again (existing account). */
export async function signIn(page, phone) {
  watchAuth(page);
  await page.goto("/login");
  await page.locator("#phone").fill(phone);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await waitForCodeStep(page, phone);
  await page.locator("#code").fill(await readCode(phone));
  await page.waitForURL((u) => !u.pathname.startsWith("/login"), { timeout: 20_000 });
  await page.waitForLoadState("networkidle");
}

/** No horizontal scrolling (RTL layouts at phone width). */
export async function expectNoSideScroll(page) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow, "page must not scroll sideways").toBeLessThanOrEqual(1);
}
