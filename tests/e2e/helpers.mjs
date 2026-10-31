import pg from "pg";
import { expect } from "@playwright/test";

const url = process.env.E2E_DB_URL || "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
if (/supabase\.co/.test(url)) throw new Error("E2E_DB_URL must be the local test database");

/** One query against the local test database (superuser: plays the admin / reads codes). */
export async function sql(text, params = []) {
  const c = new pg.Client({ connectionString: url });
  await c.connect();
  try { return (await c.query(text, params)).rows; } finally { await c.end(); }
}

/** A unique Israeli mobile for this project and role: 0521xxxxxx (mobile project) / 0522xxxxxx (desktop). */
export function phoneFor(testInfo, n) {
  const p = testInfo.project.name === "mobile" ? "1" : "2";
  const run = String(Date.now()).slice(-4);
  return `052${p}${run}${String(n).padStart(2, "0")}`.slice(0, 10);
}

async function readCode(phone) {
  const digits = "972" + phone.slice(1);
  for (let i = 0; i < 30; i++) {
    const rows = await sql("select otp from otp_outbox where regexp_replace(phone, '\\D', '', 'g') = $1 order by created_at desc limit 1", [digits]);
    if (rows[0]?.otp) return rows[0].otp;
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
    const outbox = await sql("select count(*)::int n from otp_outbox where regexp_replace(phone, '\\D', '', 'g') = $1", ["972" + phone.slice(1)]);
    throw new Error(`code request refused on screen: "${(await err.textContent())?.trim()}" (otp_outbox rows: ${outbox[0]?.n}; last auth call: ${lastAuth.get(page)})`);
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
  const rows = await sql("select id from auth.users where phone in ($1, $2)", ["972" + phone.slice(1), "+972" + phone.slice(1)]);
  return rows[0]?.id;
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
