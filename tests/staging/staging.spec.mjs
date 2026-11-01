// Hosted STAGING journeys, through the app and Supabase Auth only (no database access, no service keys).
// Accounts: the five fixed test accounts (Supabase test numbers with fixed codes from GitHub Environment secrets).
// Re-runnable: nothing is created that a later run depends on; the one booking made per run is cancelled in the same
// test, and messages carry a unique run marker. Sign-in codes are never printed (no traces, screenshots or reports).
import { test, expect } from "@playwright/test";
import { ACCOUNTS, DRY_RUN, FORBIDDEN_HOSTS, TARGET } from "./guard.mjs";

test.describe.configure({ mode: "serial" });

const RUN = `run-${Date.now().toString(36)}`;
const OFFER = "رياضيات بجروت 5 وحدات";        // Samer's private lesson (demo seed, instant confirmation)
const CHILD = "يوسف التجريبي";                 // the parent's child (staging data)
const sessions = {};                           // role -> storage state (in memory only)
const violations = [];                         // production hosts the browser tried to reach

/** Every request of a context is checked: production hosts are blocked and fail the test; Supabase must be staging. */
async function guard(context) {
  await context.route("**/*", (route) => {
    const host = new URL(route.request().url()).hostname;
    if (FORBIDDEN_HOSTS.some((re) => re.test(host))) { violations.push(host); return route.abort("blockedbyclient"); }
    if (/\.supabase\.co$/.test(host) && host !== TARGET.supabaseHost) { violations.push(host); return route.abort("blockedbyclient"); }
    return route.continue();
  });
}
test.afterEach(() => { expect(violations, "requests to production or a non-staging Supabase project").toEqual([]); });

async function newContext(browser, state) {
  // a fresh context starts from the bypass cookie (config storageState) unless a signed-in state is given
  const ctx = await browser.newContext(state ? { storageState: state } : {});
  await guard(ctx);
  return ctx;
}

/** Sign in through the real login screen with the account's fixed test code (read from the environment, never logged). */
async function as(browser, role) {
  if (sessions[role]) return newContext(browser, sessions[role]);
  const ctx = await newContext(browser);
  const page = await ctx.newPage();
  const authHosts = new Set();
  page.on("request", (r) => { if (r.url().includes("/auth/v1/")) authHosts.add(new URL(r.url()).hostname); });
  await page.goto("/login");
  await page.locator("#phone").fill(ACCOUNTS[role].phone);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await expect(page.getByRole("heading", { name: "أدخل الرمز" })).toBeVisible({ timeout: 20_000 });
  await page.locator("#code").fill(process.env[ACCOUNTS[role].otpVar]);
  await page.waitForURL((u) => !u.pathname.startsWith("/login"), { timeout: 20_000 });
  await page.waitForLoadState("networkidle");
  expect([...authHosts], "sign-in went to the classi-staging Supabase project").toEqual([TARGET.supabaseHost]);
  sessions[role] = await ctx.storageState();
  await page.close();
  return ctx;
}

test("S1. staging build: marked, never indexed, protected host only", async ({ page, request }) => {
  test.skip(DRY_RUN, "the CI dry run uses a local build, not a staging build");
  await guard(page.context());
  const robots = await (await request.get("/robots.txt")).text();
  expect(robots).toMatch(/Disallow: \/\s*$/m);
  const res = await page.goto("/");
  expect(new URL(page.url()).hostname).toBe(TARGET.appHost);
  expect(res?.headers()["x-robots-tag"]).toContain("noindex");
  await expect(page.locator(".staging-bar")).toBeVisible();
  await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);
  await expect(page.locator(".support-fab")).toHaveCount(0);   // no real WhatsApp number on staging
});

test("S2. visitor: search, offer page asks to sign in before booking", async ({ page }) => {
  await guard(page.context());
  await page.goto(`/search?q=${encodeURIComponent(OFFER)}`);
  await page.locator("a[href^='/offer/']").filter({ hasText: OFFER }).first().click();
  await expect(page.getByRole("link", { name: "سجّل الدخول للحجز" })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBeLessThanOrEqual(1);
});

test("S3. permissions: only the admin opens the admin page; each role sees its own dashboard", async ({ browser }) => {
  for (const role of ["teacher", "institute", "parent", "student"]) {
    const ctx = await as(browser, role); const p = await ctx.newPage();
    await p.goto("/admin");
    await expect(p.getByRole("heading", { name: "هذه الصفحة للمدير فقط" }), `${role} must not open /admin`).toBeVisible();
    await expect(p.locator("nav.tabs")).toHaveCount(0);
    await ctx.close();
  }
  const a = await as(browser, "admin"); const ap = await a.newPage();
  await ap.goto("/admin");
  await expect(ap.locator("nav.tabs")).toBeVisible();
  await ap.goto("/admin?tab=review");
  await expect(ap.getByRole("link", { name: /المراجعة/ })).toHaveAttribute("aria-current", "page");
  await ap.goto("/admin?tab=health");
  // SMS can never really go out from staging: no 019 token exists in the staging project.
  await expect(ap.getByText(/SMS_019_TOKEN/)).toBeVisible({ timeout: 30_000 });
  await a.close();

  const t = await as(browser, "teacher"); const tp = await t.newPage();
  await tp.goto("/teach");
  await expect(tp.getByRole("heading", { name: /لوحتي/ })).toBeVisible();
  await expect(tp.getByText(OFFER).first()).toBeVisible();
  await t.close();

  const i = await as(browser, "institute"); const ip = await i.newPage();
  await ip.goto("/manage");
  await expect(ip.getByRole("heading", { name: "مركز النخبة للتعليم" })).toBeVisible();
  await expect(ip.getByText("دورة بجروت رياضيات 5 وحدات").first()).toBeVisible();
  await i.close();
});

test("S4. data isolation: the parent sees the child's lessons, the student does not", async ({ browser }) => {
  const p = await as(browser, "parent"); const pp = await p.newPage();
  await pp.goto("/schedule");
  await expect(pp.getByRole("heading", { name: "جدولي" })).toBeVisible();
  await expect(pp.locator(".card.lesson").filter({ hasText: OFFER }).filter({ hasText: CHILD }).first()).toBeVisible();
  await p.close();

  const s = await as(browser, "student"); const sp = await s.newPage();
  await sp.goto("/schedule");
  await expect(sp.locator(".card.lesson").filter({ hasText: "مجموعة تقوية رياضيات" }).first()).toBeVisible();
  await expect(sp.getByText(CHILD)).toHaveCount(0);
  await sp.goto("/messages");
  await expect(sp.locator("a[href^='/messages/']")).toHaveCount(0);
  await s.close();
});

test("S5. booking and cancellation by the parent (cancelled in the same run)", async ({ browser }) => {
  const ctx = await as(browser, "parent"); const page = await ctx.newPage();
  await page.goto(`/search?q=${encodeURIComponent(OFFER)}`);
  await page.locator("a[href^='/offer/']").filter({ hasText: OFFER }).first().click();
  await page.getByRole("button", { name: "اختر موعداً" }).click();
  const dialog = page.getByRole("dialog");
  // a day at least 4 days ahead (outside the 24-hour cancellation window), first free time
  const days = dialog.locator("button.day");
  const day = days.nth(Math.min(4, (await days.count()) - 1));
  await day.click();
  const dayNum = (await day.locator("b.num").textContent())?.trim();
  const slot = dialog.locator("button.slot:not([disabled])").first();
  const time = (await slot.textContent())?.trim();
  await slot.click();
  const primary = dialog.locator(".row button.btn:not(.ghost)");
  for (let i = 0; i < 6; i++) {
    for (const choice of [/حصة واحدة/, /أونلاين/, new RegExp(CHILD.split(" ")[0]), /نقداً/]) {
      const opt = dialog.locator("button.opt", { hasText: choice });
      if (await opt.count() && (await opt.first().getAttribute("aria-pressed")) !== "true") await opt.first().click();
    }
    const label = (await primary.textContent())?.trim();
    await primary.click();
    if (label !== "التالي") break;
  }
  await page.waitForURL(/\/schedule/);
  const card = page.locator(".card.lesson").filter({ hasText: OFFER }).filter({ hasText: time }).filter({ has: page.locator(".date b.num", { hasText: new RegExp(`^${dayNum}$`) }) });
  await expect(card).toHaveCount(1);
  await card.getByText("إلغاء الحجز").click();
  await page.getByRole("button", { name: "تأكيد الإلغاء" }).click();
  await expect(card).toHaveCount(0, { timeout: 20_000 });
  await ctx.close();
});

test("S6. messages and notifications: parent writes, the teacher sees it and gets a notice", async ({ browser }) => {
  const text = `رسالة اختبار تلقائي ${RUN}`;
  const p = await as(browser, "parent"); const pp = await p.newPage();
  await pp.goto("/messages");
  await pp.locator("a[href^='/messages/']").first().click();
  await pp.getByLabel("اكتب رسالة").fill(text);
  await pp.getByRole("button", { name: "إرسال" }).click();
  await expect(pp.getByText(text)).toBeVisible();
  await p.close();

  const t = await as(browser, "teacher"); const tp = await t.newPage();
  await tp.goto("/");
  await expect(tp.locator("a.hdr-bell")).toHaveAttribute("aria-label", /جديدة/);
  await tp.goto("/messages");
  await tp.locator("a[href^='/messages/']").first().click();
  await expect(tp.getByText(text)).toBeVisible();
  await tp.goto("/notifications");
  await expect(tp.locator("a.notice").first()).toBeVisible();
  await t.close();
});
