// Hosted STAGING journeys, through the app and Supabase Auth only (no database access, no service keys).
// Accounts: the five fixed test accounts (Supabase test numbers with fixed codes from GitHub Environment secrets).
// Re-runnable: nothing is created that a later run depends on. Every change is undone in the same test (bookings are
// cancelled or declined, a new offer is deleted, hours and settings are put back, a photo is removed), and the CI dry
// run compares a snapshot of that data before and after the suite. Messages carry a unique run marker. Sign-in codes are never printed (no traces, screenshots or reports).
import { test, expect } from "@playwright/test";
import { ACCOUNTS, DRY_RUN, FORBIDDEN_HOSTS, TARGET } from "./guard.mjs";

test.describe.configure({ mode: "serial" });

const RUN = `run-${Date.now().toString(36)}`;
const OFFER = "رياضيات بجروت 5 وحدات";        // Samer's private lesson (demo seed, instant confirmation; S9 turns it off and back on)
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

async function newContext(browser, state, extra = {}) {
  // a fresh context starts from the bypass cookie (config storageState) unless a signed-in state is given
  const ctx = await browser.newContext({ ...(state ? { storageState: state } : {}), ...extra });
  await guard(ctx);
  return ctx;
}

/** Sign in through the real login screen with the account's fixed test code (read from the environment, never logged). */
async function as(browser, role, extra = {}) {
  if (sessions[role]) return newContext(browser, sessions[role], extra);
  const ctx = await newContext(browser, undefined, extra);
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
  await pp.locator("a[href^='/messages/']").filter({ hasText: "سامر" }).first().click();
  await pp.getByLabel("اكتب رسالة").fill(text);
  await pp.getByRole("button", { name: "إرسال" }).click();
  await expect(pp.getByText(text)).toBeVisible();
  await pp.reload();                                   // saved, not only shown on screen
  await expect(pp.getByText(text)).toBeVisible();
  await p.close();

  const t = await as(browser, "teacher"); const tp = await t.newPage();
  await tp.goto("/");
  await expect(tp.locator("a.hdr-bell")).toHaveAttribute("aria-label", /جديدة/);
  await tp.goto("/messages");
  // the conversation list shows the last message: the parent's new one opens the right conversation
  const threads = tp.locator("a[href^='/messages/']");
  await expect(threads.first()).toBeVisible();
  console.log(`[staging] teacher threads: ${(await threads.allTextContents()).map((t) => t.replace(/\s+/g, " ").trim().slice(0, 80)).join(" | ")}`);
  await threads.filter({ hasText: RUN }).first().click();
  await expect(tp.getByText(text)).toBeVisible();
  await tp.goto("/notifications");
  await expect(tp.locator("a.notice").first()).toBeVisible();
  await t.close();
});

// ---------------------------------------------------------------------------------------------------------------
// Phase 6: S7-S12. Same rules as above: UI only, test accounts only, every change undone in the same test.
// ---------------------------------------------------------------------------------------------------------------
import { createRequire } from "node:module";
const requireCjs = createRequire(import.meta.url);
let AXE = null;
try { AXE = requireCjs.resolve("axe-core/axe.min.js"); } catch { /* installed by the workflows; without it S7 fails below */ }

/** Relative luminance (WCAG) of a CSS rgb()/rgba() colour. */
const LUM = `(c) => { const v = (c.match(/[\\d.]+/g) || [0, 0, 0]).slice(0, 3).map(Number).map((x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4; }); return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]; }`;

/** The offer id of Samer's private lesson, from the public search page. */
async function offerId(page) {
  await page.goto(`/search?q=${encodeURIComponent(OFFER)}`);
  const href = await page.locator("a[href^='/offer/']").filter({ hasText: OFFER }).first().getAttribute("href");
  return href.replace("/offer/", "").split(/[?#]/)[0];
}

/** Books OFFER for the child on the n-th day of the picker (first free time); returns { time, dayNum }. */
async function bookAsParent(page, dayIndex) {
  await page.goto(`/search?q=${encodeURIComponent(OFFER)}`);
  await page.locator("a[href^='/offer/']").filter({ hasText: OFFER }).first().click();
  await page.getByRole("button", { name: "اختر موعداً" }).click();
  const dialog = page.getByRole("dialog");
  const days = dialog.locator("button.day");
  const day = days.nth(Math.min(dayIndex, (await days.count()) - 1));
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
  return { time, dayNum };
}
const lessonCard = (page, { time, dayNum }) => page.locator(".card.lesson").filter({ hasText: OFFER }).filter({ hasText: time })
  .filter({ has: page.locator(".date b.num", { hasText: new RegExp(`^${dayNum}$`) }) });

async function cancelFromSchedule(page, b) {
  await page.goto("/schedule");
  const card = lessonCard(page, b);
  await card.getByText("إلغاء الحجز").click();
  await page.getByRole("button", { name: "تأكيد الإلغاء" }).click();
  await expect(card).toHaveCount(0, { timeout: 20_000 });
}

test("S7. Arabic right-to-left, light and dark: home, search, offer, my schedule, messages", async ({ browser }, info) => {
  expect(AXE, "axe-core must be installed for the accessibility part of S7").toBeTruthy();
  await (await as(browser, "parent")).close();                 // signs in once (session kept in memory)
  const probe = await newContext(browser, sessions.parent); const pp = await probe.newPage();
  const offer = `/offer/${await offerId(pp)}`;
  await probe.close();
  const pages = [["/", "home"], [`/search?q=${encodeURIComponent(OFFER)}`, "search"], [offer, "offer"], ["/schedule", "schedule"], ["/messages", "messages"]];
  const problems = [];
  for (const scheme of ["light", "dark"]) {
    const ctx = await newContext(browser, sessions.parent, { colorScheme: scheme }); const page = await ctx.newPage();
    for (const [url, label] of pages) {
      const res = await page.goto(url, { waitUntil: "networkidle" });
      await page.waitForTimeout(2600);                         // the opening splash fades out first
      const r = await page.evaluate(`(() => { const lum = ${LUM}; const b = getComputedStyle(document.body);
        const bg = lum(b.backgroundColor), fg = lum(b.color);
        return { dir: document.documentElement.dir, lang: document.documentElement.lang, bg, fg,
          contrast: (Math.max(bg, fg) + 0.05) / (Math.min(bg, fg) + 0.05),
          overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
          error: !!document.querySelector("h1") && /تعذّر فتح الصفحة|الصفحة غير موجودة/.test(document.querySelector("h1").textContent) }; })()`);
      await page.addScriptTag({ path: AXE });
      const axe = await page.evaluate(async () => {
        // eslint-disable-next-line no-undef
        const x = await axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
        return x.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => `${v.id} x${v.nodes.length}`);
      });
      const tag = `${info.project.name} ${scheme} ${label}`;
      console.log(`[S7] ${tag} | http ${res?.status()} | dir ${r.dir} lang ${r.lang} | background luminance ${r.bg.toFixed(3)} | text contrast ${r.contrast.toFixed(1)}:1 | sideways ${r.overflow}px | axe serious/critical: ${axe.length ? axe.join(", ") : "none"}`);
      if ((res?.status() ?? 0) >= 400 || r.error) problems.push(`${tag}: page error`);
      if (r.dir !== "rtl" || r.lang !== "ar") problems.push(`${tag}: not Arabic right-to-left (${r.dir}/${r.lang})`);
      if (scheme === "light" ? r.bg < 0.8 : r.bg > 0.05) problems.push(`${tag}: background not ${scheme} (${r.bg.toFixed(3)})`);
      if (r.contrast < 4.5) problems.push(`${tag}: text contrast ${r.contrast.toFixed(1)}:1`);
      if (r.overflow > 1) problems.push(`${tag}: scrolls sideways ${r.overflow}px`);
      problems.push(...axe.map((v) => `${tag}: axe ${v}`));
    }
    await ctx.close();
  }
  expect(problems, problems.join("\n")).toEqual([]);
});

test("S8. teacher: change the hours and put them back; create a test offer and delete it", async ({ browser }) => {
  const t = await as(browser, "teacher"); const page = await t.newPage();
  const form = page.locator("#kf-saveAvailability");
  // every field of the hours form, to put back exactly; and the hours as the server reads them
  const fields = () => form.evaluate((f) => [...f.elements].filter((e) => e.name).map((e) => ({ name: e.name, value: e.value, checked: e.checked ?? null })));
  const hours = () => form.evaluate((f) => { const d = new FormData(f); const rows = [];
    for (let w = 0; w <= 6; w++) { if (d.get(`on_${w}`) !== "on") continue;
      for (const [a, b] of [[`from_${w}`, `to_${w}`], [`from2_${w}`, `to2_${w}`]]) if (d.get(a) && d.get(b)) rows.push(`${w} ${d.get(a)}-${d.get(b)}`); }
    return { rows, buffer: d.get("buffer") }; });
  const setFields = (list) => form.evaluate((f, list) => { for (const x of list) { const e = f.elements.namedItem(x.name); if (!e) continue;
    if (e.type === "checkbox") e.checked = x.checked; else e.value = x.value; } }, list);
  const save = async () => { await form.getByRole("button", { name: "حفظ الأوقات" }).click(); await expect(page.locator("#hours .okmsg")).toBeVisible({ timeout: 15_000 }); };

  await page.goto("/teach#hours");
  if (await page.getByText("هذه أوقات مقترحة").count()) console.log("[S8] note: these hours were still the suggested default; saving marks them confirmed (one-time flag hours_confirmed_at)");
  const original = await fields(); const originalHours = await hours();
  console.log(`[S8] hours before: ${originalHours.rows.join(", ")} | break ${originalHours.buffer}`);
  let changed = false;
  try {
    const sat = original.find((x) => x.name === "on_6");
    const changes = [{ name: "on_6", checked: true }, { name: "from_6", value: "09:00" }, { name: "to_6", value: "10:00" },
      { name: "buffer", value: originalHours.buffer === "15" ? "5" : "15" }];
    expect(sat?.checked, "Saturday must be off before the test (it is turned on and back off)").toBe(false);
    await setFields(changes); changed = true; await save();
    const after = await hours();
    expect(after.rows).toContain("6 09:00-10:00");
    expect(after.buffer).toBe(changes[3].value);
  } finally {
    if (changed) { await page.goto("/teach#hours"); await setFields(original); await save(); }
  }
  await page.goto("/teach#hours");
  expect(await hours(), "hours and break are exactly as before").toEqual(originalHours);

  // A new offer (never shown to families: it waits for review) and its deletion
  const mineTitles = async () => { await page.goto("/teach"); return (await page.locator("section").filter({ has: page.getByRole("heading", { name: "عروضي" }) }).locator("a[href^='/offer/']").allTextContents()).map((x) => x.trim()); };
  const before = await mineTitles();
  const title = `عرض اختبار آلي ${RUN}`;
  let created = false;
  try {
    await page.goto("/teach/new");
    await page.locator("#title").fill(title);
    await page.locator("#place").selectOption("online");
    await page.locator("#link").fill("https://example.com/classi-staging-test");
    await page.getByRole("button", { name: "نشر العرض" }).click();
    await page.waitForURL(/\/teach\?ok=published/); created = true;
    const item = page.locator(".stack").filter({ hasText: title }).first();
    await expect(item.getByText("بانتظار موافقة الإدارة")).toBeVisible();
    // not visible to families before review
    const v = await newContext(browser); const vp = await v.newPage();
    await vp.goto(`/search?q=${encodeURIComponent(title)}`);
    await expect(vp.locator("a[href^='/offer/']").filter({ hasText: title })).toHaveCount(0);
    await v.close();
  } finally {
    if (created) {
      await page.goto("/teach");
      const item = page.locator(".stack").filter({ hasText: title }).first();
      await item.locator("summary", { hasText: "حذف العرض نهائياً" }).click();
      await item.getByRole("button", { name: "نعم، احذف" }).click();
      await page.waitForURL(/ok=deleted/);
    }
  }
  expect(await mineTitles(), "the teacher's offers are exactly as before").toEqual(before);
  await t.close();
});

test("S9. booking that needs the teacher: accept (then the parent cancels) and decline; instant confirmation put back", async ({ browser }) => {
  const t = await as(browser, "teacher"); const tp = await t.newPage();
  const id = await offerId(tp);
  const setInstant = async (on) => {
    await tp.goto(`/manage/course/${id}?edit=1`);
    const f = tp.locator("form").filter({ has: tp.locator('input[name="auto_confirm"]') });
    await f.locator('input[name="auto_confirm"]').setChecked(on);
    await f.getByRole("button", { name: "حفظ التعديلات" }).click();
    await tp.waitForURL(/saved=offer/);
    await tp.goto("/teach");
    const card = tp.locator(".stack").filter({ has: tp.locator(`a[href="/offer/${id}"]`) }).first();
    await expect(card.getByText("تأكيد فوري")).toHaveCount(on ? 1 : 0);
    await expect(card.getByText(/بانتظار/), "changing only instant confirmation must not send the offer to review").toHaveCount(0);
  };
  const requestCard = (b) => tp.locator("section").filter({ has: tp.getByRole("heading", { name: "طلبات حجز" }) }).locator(".card").filter({ hasText: OFFER }).filter({ hasText: b.time });

  const p = await as(browser, "parent"); const pp = await p.newPage();
  let instantOff = false;
  try {
    await setInstant(false); instantOff = true;

    // 1. a request the teacher accepts; the parent then cancels it
    const b1 = await bookAsParent(pp, 5);
    await expect(lessonCard(pp, b1).getByText("بانتظار موافقة المعلم")).toBeVisible();
    await tp.goto("/teach");
    await requestCard(b1).getByRole("button", { name: "قبول" }).click();
    await expect(requestCard(b1)).toHaveCount(0, { timeout: 20_000 });
    await pp.goto("/schedule");
    await expect(lessonCard(pp, b1).getByText("مؤكد")).toBeVisible();
    await cancelFromSchedule(pp, b1);

    // 2. a request the teacher declines; the parent is told and the time is free again
    const b2 = await bookAsParent(pp, 6);
    await expect(lessonCard(pp, b2).getByText("بانتظار موافقة المعلم")).toBeVisible();
    await tp.goto("/teach");
    await requestCard(b2).getByRole("button", { name: "رفض" }).click();
    await tp.getByRole("button", { name: "تأكيد الرفض" }).click();
    await expect(requestCard(b2)).toHaveCount(0, { timeout: 20_000 });
    await pp.goto("/schedule");
    await expect(lessonCard(pp, b2)).toHaveCount(0);
    await pp.goto("/notifications");
    await expect(pp.locator("a.notice").filter({ hasText: "اعتذر المعلم عن الموعد" }).filter({ hasText: OFFER }).first()).toBeVisible();
  } finally {
    if (instantOff) await setInstant(true);
  }
  await p.close(); await t.close();
});

test("S10. photo: the student uploads a profile photo (stored on staging only) and removes it again", async ({ browser }) => {
  const s = await as(browser, "student"); const page = await s.newPage();
  await page.goto("/account");
  const box = page.locator(".photo-up");
  const photo = box.locator("img.photo");
  await expect(box).toBeVisible();
  expect(await photo.count(), "the student account has no photo before the test (so 'no photo' is the state to come back to)").toBe(0);
  // a tiny synthetic picture (1x1 PNG), no real image
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
  let uploaded = false;
  try {
    await box.locator('input[type="file"]').setInputFiles({ name: "classi-test.png", mimeType: "image/png", buffer: png });
    await expect(photo).toHaveCount(1, { timeout: 20_000 }); uploaded = true;
    const src = await photo.getAttribute("src");
    const u = new URL(src);
    expect(u.hostname, "stored in the classi-staging project").toBe(TARGET.supabaseHost);
    expect(u.pathname).toMatch(/^\/storage\/v1\/object\/public\/avatars\/[0-9a-f-]{36}\/profile\.jpg$/);
    const got = await s.request.get(src);
    expect(got.status()).toBe(200);
    expect(got.headers()["content-type"]).toContain("image/jpeg");
    await page.reload();
    await expect(photo, "saved, not only shown").toHaveCount(1);
    console.log(`[S10] uploaded to ${u.hostname}${u.pathname.replace(/[0-9a-f-]{36}/, "<student>")} (HTTP ${got.status()}, ${got.headers()["content-type"]})`);

    await box.getByRole("button", { name: "إزالة الصورة" }).click();
    await expect(photo).toHaveCount(0, { timeout: 20_000 }); uploaded = false;
    await page.reload();
    await expect(photo).toHaveCount(0);
    await expect(box.getByRole("button", { name: "رفع صورة شخصية" })).toBeVisible();
    const gone = await s.request.get(`${u.origin}${u.pathname}`);
    expect(gone.status(), "the file itself is deleted from storage").toBeGreaterThanOrEqual(400);
    console.log(`[S10] removed: page shows no photo, file answers HTTP ${gone.status()}`);
  } finally {
    if (uploaded) { await page.goto("/account"); if (await photo.count()) await box.getByRole("button", { name: "إزالة الصورة" }).click(); }
  }
  await s.close();
});

test("S11. /account opens for each of the five roles (profile, photo box, details)", async ({ browser }) => {
  for (const role of ["teacher", "institute", "parent", "student", "admin"]) {
    const ctx = await as(browser, role); const page = await ctx.newPage();
    const res = await page.goto("/account", { waitUntil: "networkidle" });
    expect(res?.status(), `${role}: /account`).toBeLessThan(400);
    await expect(page.locator("h1").first()).not.toHaveText(/تعذّر فتح الصفحة|الصفحة غير موجودة/);
    await expect(page.locator(".photo-up"), `${role}: photo box (PhotoUpload)`).toBeVisible();
    await expect(page.getByRole("heading", { name: "بياناتي" })).toBeVisible();
    if (role === "parent") await expect(page.getByText(CHILD).first()).toBeVisible();
    await ctx.close();
  }
});

test("S12. admin: every tab of the admin page opens (nothing is approved, rejected or changed)", async ({ browser }) => {
  const a = await as(browser, "admin"); const page = await a.newPage();
  const tabs = [["ops", "العمليات"], ["review", "المراجعة"], ["subs", "الاشتراكات والإطلاق"], ["reports", "البلاغات"], ["verify", "التوثيق"], ["users", "الحسابات"], ["log", "سجلّ الإجراءات"], ["health", "حالة النظام"]];
  for (const [k, label] of tabs) {
    const res = await page.goto(`/admin?tab=${k}`, { waitUntil: "networkidle" });
    expect(res?.status(), `/admin?tab=${k}`).toBeLessThan(400);
    await expect(page.getByRole("heading", { name: "لوحة الإدارة" })).toBeVisible();
    await expect(page.locator("nav.tabs a[aria-current='page']")).toHaveText(new RegExp(label));
    await expect(page.locator("h1").first()).not.toHaveText(/تعذّر فتح الصفحة/);
  }
  await a.close();
});
