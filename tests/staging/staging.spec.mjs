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
// On failure, print what each open page shows (address, heading, messages), so the log explains the cause. No codes,
// cookies or form values are printed.
test.afterEach(async ({ browser }, info) => {
  if (info.status === info.expectedStatus) return;
  for (const ctx of browser.contexts()) for (const p of ctx.pages()) {
    const u = new URL(p.url()); const h = await p.locator("h1, h2").first().textContent({ timeout: 2000 }).catch(() => "");
    const msg = await p.locator(".err, .okmsg, [role=alert], [role=dialog] .err").allTextContents().catch(() => []);
    console.log(`[page] ${u.pathname}${u.search} | h: ${(h ?? "").trim().slice(0, 80)} | messages: ${msg.map((m) => m.trim()).filter(Boolean).join(" / ").slice(0, 300)}`);
  }
});

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

/** "My schedule" folds past lessons into "الحصص السابقة"; open it so upcoming and past lessons are both shown. */
async function openPastLessons(page) {
  const folded = page.locator("details").filter({ has: page.locator("summary", { hasText: "الحصص السابقة" }) });
  const n = await folded.count();
  for (let i = 0; i < n; i++) await folded.nth(i).evaluate((d) => { d.open = true; });
  return n > 0;
}

test("S4. data isolation: the parent sees the child's lessons, the student does not (upcoming or past)", async ({ browser }) => {
  // The staging data's lessons are fixed dates: they move from "upcoming" to the folded "past" section with time,
  // so both sections are searched (no dependence on today's date).
  const p = await as(browser, "parent"); const pp = await p.newPage();
  await pp.goto("/schedule");
  await expect(pp.getByRole("heading", { name: "جدولي" })).toBeVisible();
  console.log(`[S4] parent: past lessons section ${(await openPastLessons(pp)) ? "opened" : "absent"}`);
  await expect(pp.locator(".card.lesson").filter({ hasText: OFFER }).filter({ hasText: CHILD }).first()).toBeVisible();
  // proof that the isolation check below really fails on a leak: on the parent's page (which does show the child)
  // the same assertion must throw
  const parentHtml = await pp.content();
  expect(() => expect(parentHtml).not.toContain(CHILD), "the isolation check must fail on a page that shows the child").toThrow();
  await p.close();

  const s = await as(browser, "student"); const sp = await s.newPage();
  await sp.goto("/schedule");
  await expect(sp.getByRole("heading", { name: "جدولي" })).toBeVisible();
  console.log(`[S4] student: past lessons section ${(await openPastLessons(sp)) ? "opened" : "absent"}`);
  await expect(sp.locator(".card.lesson").filter({ hasText: "مجموعة تقوية رياضيات" }).first()).toBeVisible();
  // Strict: nothing of the child anywhere in the student's page, folded or not: the whole HTML is searched (hidden
  // and folded content included), and no lesson card of the parent's private lesson exists, visible or hidden.
  expect(await sp.content(), "the child's name must not be in the student's schedule (even folded)").not.toContain(CHILD);
  await expect(sp.locator(".card.lesson").filter({ hasText: OFFER })).toHaveCount(0);
  await sp.goto("/messages");
  await expect(sp.locator("a[href^='/messages/']")).toHaveCount(0);
  expect(await sp.content(), "the parent's conversation must not be in the student's messages").not.toContain(CHILD);
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
  await page.waitForURL(/\/schedule/, { timeout: 20_000 });
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
  test.setTimeout(240_000);
  const t = await as(browser, "teacher"); const tp = await t.newPage();
  const id = await offerId(tp);
  const setInstant = async (page, on) => {
    await page.goto(`/manage/course/${id}?edit=1`);
    const f = page.locator("form").filter({ has: page.locator('input[name="auto_confirm"]') });
    await f.locator('input[name="auto_confirm"]').setChecked(on);
    await f.getByRole("button", { name: "حفظ التعديلات" }).click();
    await page.waitForURL(/saved=offer/);
    await page.goto("/teach");
    const card = page.locator(".stack").filter({ has: page.locator(`a[href="/offer/${id}"]`) }).first();
    await expect(card.getByText("تأكيد فوري")).toHaveCount(on ? 1 : 0);
    await expect(card.getByText(/بانتظار/), "changing only instant confirmation must not send the offer to review").toHaveCount(0);
  };
  const requestCard = (b) => tp.locator("section").filter({ has: tp.getByRole("heading", { name: "طلبات حجز" }) }).locator(".card").filter({ hasText: OFFER }).filter({ hasText: b.time });

  // Before any change: the deployed build must have the Phase 6 fix (no default package size sent with every save),
  // otherwise saving this form would send Samer's offer to admin review. The fixed form leaves the size empty.
  await tp.goto(`/manage/course/${id}?edit=1`);
  const editForm = tp.locator("form").filter({ has: tp.locator('input[name="auto_confirm"]') });
  if (!(await editForm.locator('input[name="package_on"]').isChecked())) {
    expect(await editForm.locator('input[name="package_size"]').inputValue(),
      "deployed build lacks the Phase 6 package fix: deploy it to staging before running S9 (nothing was changed)").toBe("");
  }
  const p = await as(browser, "parent"); const pp = await p.newPage();
  const made = [];                                             // bookings this test created (undone in finally)
  let instantOff = false;
  try {
    await setInstant(tp, false); instantOff = true;

    // 1. a request the teacher accepts; the parent then cancels it
    const b1 = await bookAsParent(pp, 5); made.push(b1);
    await expect(lessonCard(pp, b1).getByText("بانتظار موافقة المعلم")).toBeVisible();
    await tp.goto("/teach");
    console.log(`[S9] teacher requests: ${(await tp.locator("section").filter({ has: tp.getByRole("heading", { name: "طلبات حجز" }) }).locator(".card").allTextContents()).map((x) => x.replace(/\s+/g, " ").trim().slice(0, 90)).join(" | ") || "none"} (looking for ${b1.time})`);
    await requestCard(b1).getByRole("button", { name: "قبول", exact: true }).click();
    await expect(requestCard(b1)).toHaveCount(0, { timeout: 20_000 });
    await pp.goto("/schedule");
    await expect(lessonCard(pp, b1).getByText("مؤكد")).toBeVisible();
    await cancelFromSchedule(pp, b1); made.pop();

    // 2. a request the teacher declines; the parent is told and the time is free again
    const b2 = await bookAsParent(pp, 6); made.push(b2);
    await expect(lessonCard(pp, b2).getByText("بانتظار موافقة المعلم")).toBeVisible();
    await tp.goto("/teach");
    // "رفض" opens a confirmation (<details>/<summary>, works without JavaScript); the real button is inside it
    await requestCard(b2).locator("summary", { hasText: "رفض" }).click();
    await requestCard(b2).getByRole("button", { name: "تأكيد الرفض" }).click();
    await expect(requestCard(b2)).toHaveCount(0, { timeout: 20_000 }); made.pop();
    await pp.goto("/schedule");
    await expect(lessonCard(pp, b2)).toHaveCount(0);
    await pp.goto("/notifications");
    await expect(pp.locator("a.notice").filter({ hasText: "اعتذر المعلم عن الموعد" }).filter({ hasText: OFFER }).first()).toBeVisible();
  } finally {
    // undo with fresh pages, so a failure above (or a closed page) cannot stop the cleanup
    if (made.length) {
      const c = await as(browser, "parent"); const cp = await c.newPage();
      for (const b of made) await cancelFromSchedule(cp, b).catch((e) => console.log(`[S9] cleanup: could not cancel ${b.dayNum} ${b.time}: ${e.message.split("\n")[0]}`));
      await c.close();
    }
    if (instantOff) { const c = await as(browser, "teacher"); await setInstant(await c.newPage(), true); await c.close(); }
  }
  await p.close(); await t.close();
});

// ---- Is a photo file really in storage, and who can reach it? ----
// Since private photos (migrations 20261105000000/010000): users upload only to the private bucket "photos-private";
// a teacher's new photo waits there until the admin publishes it to the public bucket "avatars"; profile photos stay
// private and are shown through short signed links. Whether a file exists is asked from Supabase Storage itself (its
// list API, not cached by the CDN; hosted run 41716623354), with a signed-in user's own session, exactly what that user
// can see. The owner's session comes from the page's own upload request; another user's from that user's sign-in
// cookie. Sessions are kept in memory and never printed. Public links are only logged, for information.
const PRIV = "photos-private", PUB = "avatars";
function storageWatcher(page) {
  const w = { origin: null, headers: null, uploads: [] };     // uploads: { bucket, key: "<owner id>/…" } of each upload
  page.on("request", async (r) => {
    const u = new URL(r.url());
    const m = u.pathname.match(/^\/storage\/v1\/object\/(avatars|photos-private)\/(.+)$/);
    if (u.hostname !== TARGET.supabaseHost || r.method() !== "POST" || !m) return;
    w.uploads.push({ bucket: m[1], key: decodeURIComponent(m[2]) });
    const h = await r.allHeaders().catch(() => ({}));
    if (h.authorization && h.apikey) { w.origin = u.origin; w.headers = { authorization: h.authorization, apikey: h.apikey }; }
  });
  return w;
}
/** Another signed-in user's storage session, from that user's sign-in cookie (never printed). */
async function sessionOf(ctx, w) {
  const parts = (await ctx.cookies()).filter((c) => /^sb-.+-auth-token(\.\d+)?$/.test(c.name))
    .sort((x, y) => Number(x.name.split(".").pop()) - Number(y.name.split(".").pop()) || x.name.localeCompare(y.name));
  let raw = parts.map((c) => c.value).join("");
  if (raw.startsWith("base64-")) raw = Buffer.from(raw.slice(7), "base64url").toString("utf8");
  const token = JSON.parse(decodeURIComponent(raw)).access_token;
  expect(token, "the other user's sign-in session").toBeTruthy();
  return { origin: w.origin, headers: { apikey: w.headers.apikey, authorization: `Bearer ${token}` } };
}
/** "<owner id>/…" from a photo link: a public link (/object/public/avatars/…) or a signed one (/object/sign/photos-private/…). */
const keyOf = (src) => { const p = new URL(src).pathname; return decodeURIComponent(p.split(p.includes(`/${PRIV}/`) ? `/${PRIV}/` : `/${PUB}/`)[1]); };
const folderOf = (key) => key.slice(0, key.lastIndexOf("/"));
/** How long a signed link works, from its token (exp - iat, in seconds). */
const signedSeconds = (src) => { const t = JSON.parse(Buffer.from(new URL(src).searchParams.get("token").split(".")[1], "base64url").toString("utf8")); return t.exp - t.iat; };
/** The files in a folder of a bucket, as the given signed-in user sees them in Supabase Storage. */
async function storedFiles(request, w, folder, bucket = PUB) {
  expect(w.headers, "a storage session of a signed-in user").toBeTruthy();
  expect(new URL(w.origin).hostname, "storage of the classi-staging project").toBe(TARGET.supabaseHost);
  const res = await request.post(`${w.origin}/storage/v1/object/list/${bucket}`, {
    headers: { ...w.headers, "content-type": "application/json" },
    data: { prefix: folder, limit: 1000, offset: 0, sortBy: { column: "name", order: "asc" } },
  });
  expect(res.status(), "storage list with the user's own session").toBe(200);
  const body = await res.json();
  expect(Array.isArray(body), "storage list answered with a list").toBe(true);
  return body.filter((o) => o.id).map((o) => `${folder}/${o.name}`);
}
/** Fails if the file is still in storage after `tries` checks, one second apart (the delete itself is synchronous). */
async function expectGoneFromStorage(request, w, key, message, tries = 10, bucket = PUB) {
  let present = true;
  for (let i = 0; i < tries && present; i++) {
    present = (await storedFiles(request, w, folderOf(key), bucket)).includes(key);
    if (present && i < tries - 1) await new Promise((r) => setTimeout(r, 1000));
  }
  expect(present, message).toBe(false);
}
/** A private file must not be reachable by anyone else: not through a public link, not listed or signed by another
 * signed-in user. Returns what was tried, for the log. */
async function expectPrivate(request, owner, other, key, who) {
  const pub = await request.get(`${owner.origin}/storage/v1/object/public/${PRIV}/${key}`);
  expect(pub.status(), `${who}: no public link to a private photo`).toBeGreaterThanOrEqual(400);
  expect(await storedFiles(request, other, folderOf(key), PRIV), `${who}: another user does not see the private file`).not.toContain(key);
  const sign = await request.post(`${other.origin}/storage/v1/object/sign/${PRIV}/${key}`, { headers: { ...other.headers, "content-type": "application/json" }, data: { expiresIn: 60 } });
  expect(sign.status(), `${who}: another user cannot get a signed link to it`).toBeGreaterThanOrEqual(400);
  return `public link HTTP ${pub.status()}, another user: not listed, signing HTTP ${sign.status()}`;
}
/** Information only: what the public (CDN) link answers. A 200 here after a delete can be a cached copy. */
async function logPublicLink(request, src, tag) {
  const res = await request.get(src);
  const cache = res.headers()["cf-cache-status"] ?? "-";
  console.log(`[${tag}] public link ${new URL(src).pathname.replace(/[0-9a-f-]{36}/, "<owner>")} -> HTTP ${res.status()}, CDN cache ${cache} (information only)`);
}

test("S10. photo: the student's profile photo is private (only she can see it, through a short signed link), and removed again", async ({ browser }) => {
  const s = await as(browser, "student"); const page = await s.newPage();
  const store = storageWatcher(page);
  await page.goto("/account");
  const box = page.locator(".photo-up");
  const photo = box.locator("img.photo");
  await expect(box).toBeVisible();
  // Before any change: the deployed build uses private photos (Phase 7), or nothing would be private (nothing changed)
  await expect(box, "deployed build lacks private photos: deploy Phase 7 to staging before running S10 (nothing was changed)").toHaveAttribute("data-private", "1");
  expect(await photo.count(), "the student account has no photo before the test (so 'no photo' is the state to come back to)").toBe(0);
  // a tiny synthetic picture (1x1 PNG), no real image
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
  const p = await as(browser, "parent");            // another signed-in user
  let uploaded = false;
  try {
    await box.locator('input[type="file"]').setInputFiles({ name: "classi-test.png", mimeType: "image/png", buffer: png });
    await expect(photo.or(box.getByRole("alert")).first()).toBeVisible({ timeout: 20_000 });
    if (await box.getByRole("alert").count()) throw new Error(`upload refused on screen: ${await box.getByRole("alert").textContent()}`);
    uploaded = true;
    expect(store.uploads.map((u) => u.bucket), "uploaded to the private bucket only").toEqual([PRIV]);
    await page.reload();
    await expect(photo, "saved, not only shown").toHaveCount(1);
    const src = await photo.getAttribute("src");
    const u = new URL(src);
    expect(u.hostname, "stored in the classi-staging project").toBe(TARGET.supabaseHost);
    expect(u.pathname, "shown through a signed link to a private file of her own").toMatch(/^\/storage\/v1\/object\/sign\/photos-private\/[0-9a-f-]{36}\/profile-[0-9a-z]+-[0-9a-z]{8}\.jpg$/);
    expect(signedSeconds(src), "the signed link works one hour at most").toBeLessThanOrEqual(3600);
    const key = keyOf(src);
    expect(key, "the file of this upload").toBe(store.uploads[0].key);
    const got = await s.request.get(src);
    expect(got.status(), "the signed link opens the photo for her").toBe(200);
    expect(await storedFiles(s.request, store, folderOf(key), PRIV), "the file is in private storage (her own session)").toContain(key);
    const other = await sessionOf(p, store);
    const tried = await expectPrivate(s.request, store, other, key, "profile photo");
    // the storage check must fail on a file that exists: applied now, while the photo is in use, it has to throw
    await expect(expectGoneFromStorage(s.request, store, key, "check", 1, PRIV), "the storage check must fail while the file exists").rejects.toThrow();
    console.log(`[S10] uploaded privately to ${u.hostname}/…/photos-private/<student>/${key.split("/").pop()} (signed link ${signedSeconds(src)} s, HTTP ${got.status()}); ${tried}`);

    await box.getByRole("button", { name: "إزالة الصورة" }).click();
    await expect(photo).toHaveCount(0, { timeout: 20_000 }); uploaded = false;
    await page.reload();
    await expect(photo).toHaveCount(0);
    await expect(box.getByRole("button", { name: "رفع صورة شخصية" })).toBeVisible();
    // the app no longer shows or links the removed photo: not on the account page, not in the header of the home page
    for (const path of ["/account", "/"]) {
      await page.goto(path);
      expect(await page.content(), `${path}: the removed photo's link is gone from the page`).not.toContain(key);
    }
    await expectGoneFromStorage(s.request, store, key, "the file itself is deleted from private storage", 10, PRIV);
    console.log(`[S10] removed: no photo on the page, no link to it, file gone from private storage`);

    if (DRY_RUN) {
      // the storage check itself, proven here: a file put in the student's own private folder through the same API is
      // seen, the check fails while it exists, and passes once it is deleted (local stack only: nothing added on staging)
      const folder = folderOf(key), probe = `${folder}/profile-p${Date.now().toString(36)}-probe001.jpg`;
      const put = await s.request.post(`${store.origin}/storage/v1/object/${PRIV}/${probe}`, { headers: { ...store.headers, "content-type": "image/jpeg" }, data: png });
      expect(put.status(), "probe file stored").toBe(200);
      try {
        expect(await storedFiles(s.request, store, folder, PRIV), "the storage check sees a file that exists").toContain(probe);
        await expect(expectGoneFromStorage(s.request, store, probe, "probe", 1, PRIV), "the check must fail while the file exists").rejects.toThrow();
      } finally {
        const del = await s.request.delete(`${store.origin}/storage/v1/object/${PRIV}`, { headers: { ...store.headers, "content-type": "application/json" }, data: { prefixes: [probe] } });
        expect(del.status(), "probe file deleted").toBe(200);
      }
      await expectGoneFromStorage(s.request, store, probe, "the check passes once the file is deleted", 10, PRIV);
      console.log(`[S10] local stack: storage check proven: sees an existing file, fails on it, passes after its deletion`);
    }
  } finally {
    if (uploaded) { await page.goto("/account"); if (await photo.count()) await box.getByRole("button", { name: "إزالة الصورة" }).click(); }
    await p.close();
  }
  await s.close();
});

test("S10b. admin review: a rejection reason is shown to the owner only; teacher photo rejected, approved, replaced, removed, the approved photo stays until a new one is approved", async ({ browser }) => {
  test.setTimeout(420_000);
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
  const t = await as(browser, "teacher"); const tp = await t.newPage();
  const store = storageWatcher(tp);              // Samer's photo files, seen in storage with his own session
  const box = tp.locator("#profile .photo-up");
  // Always a real page load of the dashboard. goto() to the address the page is already on, with a "#", only moves
  // within the page (no load, the photo box is not mounted again, so its tidy-up does not run): hosted run
  // 41721336243. So exactly in that case (already on /teach#profile) the page is reloaded; any other address (also
  // /teach?ok=profile after a save) is a real navigation, which clears the "?ok=" the save waits for.
  const openTeach = async () => {
    const here = new URL(tp.url());
    if (here.pathname === "/teach" && !here.search && here.hash === "#profile") await tp.reload();
    else await tp.goto("/teach#profile");
  };
  await openTeach();
  // Before any change: the deployed build stores every upload as its own file (Phase 6), and nothing is waiting.
  await expect(box, "deployed build lacks private photos: deploy Phase 7 to staging before running S10b (nothing was changed)").toHaveAttribute("data-private", "1");

  // the public teacher page (what families see), the admin review card, and another signed-in user (the parent)
  const v = await newContext(browser); const vp = await v.newPage();
  await vp.goto(`/search?q=${encodeURIComponent(OFFER)}`);
  await vp.locator("a[href^='/offer/']").filter({ hasText: OFFER }).first().click();
  const teacherUrl = await vp.locator("a[href^='/teacher/']").first().getAttribute("href");
  const publicPhoto = async () => { await vp.goto(teacherUrl); const img = vp.locator(".profile-head img.photo").first(); return (await img.count()) ? await img.getAttribute("src") : null; };
  const a = await as(browser, "admin"); const ap = await a.newPage();
  const reviewCard = () => ap.locator(".card").filter({ hasText: "سامر مصاروة" }).filter({ has: ap.locator('input[name="kind"][value="teacher"]') });
  const decide = async (approve, note = `اختبار آلي ${RUN}`) => {
    await ap.goto("/admin?tab=review");
    const card = reviewCard().first();
    await expect(card).toBeVisible();
    if (approve) await card.getByRole("button", { name: "موافقة ونشر" }).click();
    else { await card.locator("summary", { hasText: "رفض" }).click(); await card.locator('input[name="note"]').fill(note); await card.getByRole("button", { name: "رفض" }).click(); }
    await expect(reviewCard()).toHaveCount(0, { timeout: 20_000 });
  };
  await ap.goto("/admin?tab=review");
  expect(await reviewCard().count(), "no change of Samer's profile is waiting before the test").toBe(0);

  // ---- The reason for a rejected profile edit: shown to the owner only (runs on the local stack too) ----
  {
    const bio = tp.locator("#kf-updateTeacher #e-bio");
    // the profile form sits in a folded section ("تعديل البيانات والنبذة"), opened like a user would
    const openProfileForm = async () => {
      const det = tp.locator("#profile details").filter({ has: tp.locator("summary", { hasText: "تعديل البيانات والنبذة" }) }).first();
      if (!(await det.evaluate((d) => d.open))) await det.locator("summary").click();
      await expect(bio).toBeVisible();
    };
    const saveBio = async (text) => {
      await openTeach();
      await openProfileForm();
      await bio.fill(text);
      await tp.locator("#kf-updateTeacher").getByRole("button", { name: "حفظ", exact: true }).click();
      await tp.waitForURL(/ok=profile/);
    };
    await openTeach();
    const originalBio = await bio.inputValue();
    const reason = `سبب رفض تجريبي ${RUN}`;
    const rejectedNotice = "لم تتم الموافقة على آخر تعديل لملفك";
    const p = await as(browser, "parent"); const pp = await p.newPage();
    let changed = false;
    try {
      await saveBio(`${originalBio} [S10b ${RUN}]`); changed = true;
      await expect(tp.getByText("تعديلات ملفك بانتظار موافقة الإدارة")).toBeVisible();
      // the admin sees exactly one changed field (the bio): saving the profile form must not send other fields
      await ap.goto("/admin?tab=review");
      const fields = (await reviewCard().first().locator(".summary > div > span:first-child").allTextContents()).map((x) => x.trim());
      expect(fields, "only the bio waits for review").toEqual(["النبذة"]);
      await decide(false, reason);

      // the owner sees the reason on the dashboard (the same detector, page HTML, is used for the leak checks below)
      await tp.goto("/teach");
      await expect(tp.getByText(`${rejectedNotice}: ${reason}`)).toBeVisible();
      expect(await tp.content(), "owner: the reason is in the page").toContain(reason);
      // nobody else sees it: the public teacher page for a visitor and for another signed-in user, and that
      // user's own pages; any appearance of the reason text in the HTML fails the test
      await vp.goto(teacherUrl);
      expect(await vp.content(), "visitor: the rejection reason must not appear on the public teacher page").not.toContain(reason);
      for (const path of [teacherUrl, "/", "/schedule", "/messages", "/notifications"]) {
        await pp.goto(path);
        expect(await pp.content(), `another signed-in user (parent) on ${path}: the rejection reason must not appear`).not.toContain(reason);
      }
      // proof that the leak check really fails on a leak: applied to the owner's page, which does hold the reason,
      // the same assertion must throw
      const ownerHtml = await tp.content();
      expect(() => expect(ownerHtml).not.toContain(reason), "the leak check must fail on a page that holds the reason").toThrow();
      console.log(`[S10b] rejection reason: shown to the owner; not on the public page (visitor), not on 5 pages of another user`);
    } finally {
      if (changed) {
        // back to the original bio and no reason left: two approved edits (an approval clears the reason)
        await ap.goto("/admin?tab=review");
        if (await reviewCard().count()) await decide(false, reason);
        await saveBio(`${originalBio} [S10b-2 ${RUN}]`); await decide(true);
        await saveBio(originalBio); await decide(true);
      }
      await p.close();
    }
    await openTeach();
    expect(await bio.inputValue(), "bio is back to the original").toBe(originalBio);
    await expect(tp.getByText(rejectedNotice)).toHaveCount(0);
  }

  // ---- Photos: a new photo waits PRIVATELY until the admin publishes it ----
  // Uploads go to the private bucket only. Until the admin approves, the new photo is reachable by Samer and the admin
  // only (short signed links), never through a public link, and nothing new is in the public bucket. On approval the
  // app copies it to a new name in Samer's public folder and deletes the private original; on rejection the private
  // file is deleted at once.
  const o = await as(browser, "parent"); const other = async () => sessionOf(o, store);      // another signed-in user
  const teacherFolder = async () => (await storedFiles(t.request, store, (await uidOf()), PUB)).filter((k) => /\/teacher-[^/]+$/.test(k));
  const uidOf = async () => { expect(store.uploads.length, "an upload gave Samer's folder").toBeGreaterThan(0); return store.uploads[0].key.split("/")[0]; };
  const waitingCard = () => reviewCard().first().locator("[data-waiting-photo] img.waiting-photo");
  // a new photo: uploaded privately, waiting; returns its private key
  const upload = async () => {
    await openTeach();
    const before = store.uploads.length;
    await box.locator('input[type="file"]').setInputFiles({ name: "t.png", mimeType: "image/png", buffer: png });
    await expect(box.getByRole("status")).toContainText("للمراجعة", { timeout: 20_000 });
    expect(store.uploads.length, "one upload request").toBe(before + 1);
    const up = store.uploads.at(-1);
    expect(up.bucket, "uploaded to the private bucket only").toBe(PRIV);
    expect(up.key, "a new private file under pending/").toMatch(/^[0-9a-f-]{36}\/pending\/teacher-[0-9a-z]+-[0-9a-z]{8}\.jpg$/);
    expect(await storedFiles(t.request, store, folderOf(up.key), PRIV), "the new file is in private storage").toContain(up.key);
    // the owner sees it waiting, through a short signed link, after a real page load
    await openTeach();
    const w = box.locator("img.waiting-photo");
    await expect(w, "the owner sees the waiting photo").toHaveCount(1);
    const wsrc = await w.getAttribute("src");
    expect(keyOf(wsrc), "the owner's link is to this private file").toBe(up.key);
    expect(new URL(wsrc).pathname, "a signed link").toContain(`/object/sign/${PRIV}/`);
    expect(signedSeconds(wsrc), "the owner's link works 10 minutes at most").toBeLessThanOrEqual(600);
    // nobody else: no public link, another user cannot list or sign it, and it is not on the public teacher page
    const tried = await expectPrivate(t.request, store, await other(), up.key, "waiting teacher photo");
    expect(await publicPhoto(), "families do not see the waiting photo").toBe(approvedNow);
    expect(await vp.content(), "the public teacher page has no link to the waiting photo").not.toContain(up.key.split("/").pop());
    // the admin sees it in the review card, through a 5-minute signed link
    await ap.goto("/admin?tab=review");
    await expect(waitingCard(), "the admin sees the waiting photo").toHaveCount(1);
    const asrc = await waitingCard().getAttribute("src");
    expect(keyOf(asrc), "the admin's link is to this private file").toBe(up.key);
    expect(signedSeconds(asrc), "the admin's link works 5 minutes at most").toBeLessThanOrEqual(300);
    console.log(`[S10b] waiting photo ${up.key.split("/").pop()}: private (${tried}); owner link ${signedSeconds(wsrc)} s, admin link ${signedSeconds(asrc)} s`);
    return up.key;
  };
  let approvedNow = null;
  const keys = [];
  let approvedByTest = false;
  expect(await publicPhoto(), "Samer has no photo before the test (the state to come back to)").toBeNull();
  try {
    // 1. new photo -> waits privately; the admin rejects it -> its private file is deleted at once; still no photo
    keys.push(await upload());
    const publicBefore = await teacherFolder();
    expect(publicBefore, "nothing new in Samer's public folder before approval").toEqual([]);
    await decide(false);
    await expectGoneFromStorage(t.request, store, keys[0], "rejected: the private file is deleted at once", 10, PRIV);
    expect(await publicPhoto(), "rejected: unchanged").toBeNull();

    if (DRY_RUN) {
      // local stack: publishing needs an https photo link (https://<project>.supabase.co, checked by the database), so
      // the approval and publishing part runs on hosted staging; everything above (private upload, signed links for
      // the owner and the admin, no public access, rejection deleting the file) ran here
      console.log("[S10b] local stack: private waiting photo and rejection verified; approval/publishing runs on hosted staging");
      await o.close(); await v.close(); await a.close(); await t.close();
      return;
    }

    // 2. new photo -> approved -> published: a new public file in Samer's folder, the private original deleted
    keys.push(await upload());
    await decide(true); approvedByTest = true;
    approvedNow = await publicPhoto();
    expect(approvedNow, "approved photo is shown to families").toMatch(/\/storage\/v1\/object\/public\/avatars\/[0-9a-f-]{36}\/teacher-[0-9a-z]+-[0-9a-z]{8}\.jpg$/);
    expect(keyOf(approvedNow).split("/").pop(), "published under a new name, not the private one").not.toBe(keys[1].split("/").pop());
    expect(await teacherFolder(), "exactly the published file is in Samer's public folder").toEqual([keyOf(approvedNow)]);
    await expectGoneFromStorage(t.request, store, keys[1], "published: the private original is deleted", 10, PRIV);
    console.log(`[S10b] approved: published as ${keyOf(approvedNow).split("/").pop()}, private original deleted`);

    // 3. a replacement waits privately: families keep seeing the approved photo; rejected: still the approved photo
    keys.push(await upload());
    expect(await publicPhoto(), "approved photo stays while the new one waits").toBe(approvedNow);
    expect(await teacherFolder(), "the approved file was not overwritten or deleted, nothing new public").toEqual([keyOf(approvedNow)]);
    await decide(false);
    await expectGoneFromStorage(t.request, store, keys[2], "rejected replacement: its private file is deleted at once", 10, PRIV);
    expect(await publicPhoto(), "rejected replacement: the approved photo is unchanged").toBe(approvedNow);

    // 4. removal waits for review too, then the photo is gone (back to the original state)
    await openTeach();
    await box.getByRole("button", { name: "إزالة الصورة" }).click();
    await expect(box.getByRole("status")).toContainText("للمراجعة", { timeout: 20_000 });
    expect(await publicPhoto(), "approved photo stays while the removal waits").toBe(approvedNow);
    await decide(true); approvedByTest = false;
    expect(await publicPhoto(), "removed after approval").toBeNull();
    expect(await vp.content(), "public teacher page: no link to the removed photo").not.toContain(keyOf(approvedNow));
    await openTeach();
    expect(await tp.content(), "teacher dashboard: no link to the removed photo").not.toContain(keyOf(approvedNow));

    // 5. the removed public file is cleared on the owner's next visit once old enough (an upload may still be saving)
    const wait = Math.max(0, 125_000 - (Date.now() - parseInt(keyOf(approvedNow).match(/teacher-([0-9a-z]+)-/)[1], 36)));
    console.log(`[S10b] waiting ${Math.round(wait / 1000)}s before the owner's next visit clears unused files`);
    await tp.waitForTimeout(wait);
    const tidied = tp.waitForResponse((r) => r.request().method() === "POST" && !!r.request().headers()["next-action"]
      && new URL(r.url()).pathname === "/teach", { timeout: 30_000 });
    await openTeach();
    const tidyRes = await tidied;
    expect(tidyRes.status(), "the tidy-up request was answered").toBe(200);
    let left = await teacherFolder();
    for (let i = 0; i < 15 && left.length; i++) { await tp.waitForTimeout(1000); left = await teacherFolder(); }
    const leftPrivate = (await storedFiles(t.request, store, `${await uidOf()}/pending`, PRIV));
    console.log(`[S10b] after the tidy-up: public teacher files left ${left.length}, private waiting files left ${leftPrivate.length}`);
    await logPublicLink(t.request, approvedNow, "S10b");
    expect(left, "no teacher photo file is left in Samer's public folder").toEqual([]);
    expect(leftPrivate, "no waiting photo file is left in Samer's private folder").toEqual([]);
  } finally {
    // put things back if a step failed: nothing waiting for Samer, no approved test photo
    await ap.goto("/admin?tab=review").catch(() => undefined);
    if (await reviewCard().count().catch(() => 0)) await decide(false).catch((e) => console.log(`[S10b] cleanup reject: ${e.message.split("\n")[0]}`));
    if (approvedByTest) {
      await openTeach().catch(() => undefined);
      if (await box.getByRole("button", { name: "إزالة الصورة" }).count().catch(() => 0)) {
        await box.getByRole("button", { name: "إزالة الصورة" }).click().catch(() => undefined);
        await decide(true).catch((e) => console.log(`[S10b] cleanup approve removal: ${e.message.split("\n")[0]}`));
      }
    }
    await o.close().catch(() => undefined); await v.close(); await a.close();
  }
  await t.close();
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
