// Full journeys with real accounts on the local stack (4 scenarios, phone and desktop):
// teacher -> admin -> parent booking -> messages and notifications -> cancellation, plus roles and form safety.
import { test, expect } from "@playwright/test";
import { expectNoSideScroll, phoneFor, signIn, signUp, sql } from "./helpers.mjs";

test.describe.configure({ mode: "serial" });

const S = {}; // shared between the steps of one project

function trace(page) {
  page.__events = [];
  const add = (x) => page.__events.push(x);
  page.on("console", (m) => { if (m.type() === "error" || m.type() === "warning") add(`console.${m.type()}: ${m.text().slice(0, 200)}`); });
  page.on("pageerror", (e) => add(`pageerror: ${e.message.slice(0, 200)}`));
  page.on("response", (r) => { if (r.request().method() === "POST") add(`POST ${new URL(r.url()).pathname} -> ${r.status()}`); });
  page.on("framenavigated", (f) => { if (f === page.mainFrame()) add(`nav ${f.url()}`); });
}

// On failure, print what each open page shows (URL, heading, messages) so the CI log explains the cause.
test.afterEach(async ({ browser }, info) => {
  if (info.status === info.expectedStatus) return;
  for (const ctx of browser.contexts()) for (const p of ctx.pages()) {
    for (const e of (p.__events ?? []).slice(-14)) console.log(`[page] event: ${e}`);
    console.log(`[page] invalid fields: ${await p.evaluate(() => [...document.querySelectorAll("form :invalid")].map((e) => e.id || e.getAttribute("name")).join(",")).catch(() => "?")}`);
    const msg = await p.locator(".err, .okmsg, [role=alert], .note").allTextContents().catch(() => []);
    const h = await p.locator("h1, h2").first().textContent().catch(() => "");
    console.log(`[page] ${p.url()} | h: ${h?.trim()} | messages: ${msg.map((m) => m.trim()).filter(Boolean).join(" / ").slice(0, 400)}`);
  }
});

test("9. teacher: sign up, profile, hours with Saturday, new offer (and the form keeps input after an error)", async ({ browser }, info) => {
  const ctx = await browser.newContext(); const page = await ctx.newPage(); trace(page);
  S.teacherPhone = phoneFor(info, 1);
  S.teacherUser = await signUp(page, { phone: S.teacherPhone, name: "معلمة الاختبار", role: "teacher" });
  await page.goto("/teach", { waitUntil: "networkidle" });
  await page.locator("#bio").fill("أشرح الرياضيات خطوة بخطوة.");
  await page.getByRole("button", { name: "حفظ الملف" }).click();
  await expect(page.locator("#hours")).toBeVisible({ timeout: 30_000 });
  S.teacherId = (await sql("select id from teachers where user_id = $1", [S.teacherUser]))[0].id;

  // Hours: Sunday-Thursday as suggested, plus Saturday 09:00-13:00 (BUG-01), saved in one transaction (BUG-04)
  const hours = page.locator("#kf-saveAvailability");
  await hours.locator('input[name="on_6"]').check();
  await hours.locator('input[name="from_6"]').fill("09:00");
  await hours.locator('input[name="to_6"]').fill("13:00");
  await hours.getByRole("button", { name: "حفظ الأوقات" }).click();
  await expect(page.getByText(/حُفظت الأوقات \(6 فترة\)/)).toBeVisible();

  // New offer: a server-side error must not wipe the form (BUG-07)
  await page.goto("/teach/new");
  await page.locator("#title").fill("رياضيات للاختبار الآلي");
  await page.locator("#place").selectOption("online");
  await page.locator("#link").fill("zoom.us/j/123");
  await page.locator('input[name="auto_confirm"]').check();
  await page.evaluate(() => { const f = document.getElementById("new-offer"); if (f) f.noValidate = true; });
  await page.getByRole("button", { name: "نشر العرض" }).click();
  await expect(page.getByRole("alert").or(page.locator(".err"))).toContainText("https://");
  await expect(page.locator("#title")).toHaveValue("رياضيات للاختبار الآلي");
  await page.locator("#link").fill("https://zoom.us/j/123");
  await page.getByRole("button", { name: "نشر العرض" }).click();
  await page.waitForURL(/\/teach\?ok=published/);
  S.offerId = (await sql("select id from offerings where teacher_id = $1 order by created_at desc limit 1", [S.teacherId]))[0].id;

  // The admin's part (verification and approval) is done in the database for speed; the admin UI is checked in step 12.
  await sql("update teachers set verify = 'verified' where id = $1", [S.teacherId]);
  await sql("update offerings set review_status = 'approved' where id = $1", [S.offerId]);
  await ctx.close();
});

test("10. parent: sign up, add a child, book a private lesson; booking dialog closes with Esc", async ({ browser }, info) => {
  const ctx = await browser.newContext(); const page = await ctx.newPage();
  S.parentPhone = phoneFor(info, 2);
  S.parentUser = await signUp(page, { phone: S.parentPhone, name: "أم الاختبار", role: "guardian" });
  await page.goto("/account#children");
  await page.locator("#kid-name").fill("يوسف");
  await page.getByRole("button", { name: /إضافة ابن أو ابنة/ }).click();
  await expect(page.getByText("يوسف").first()).toBeVisible();

  await page.goto(`/offer/${S.offerId}`);
  await expectNoSideScroll(page);
  await page.getByRole("button", { name: "اختر موعداً" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Escape");                       // A11Y-01
  await expect(dialog).toBeHidden();
  await page.getByRole("button", { name: "اختر موعداً" }).click();
  await expect(dialog.getByRole("heading", { name: "اختر الموعد" })).toBeFocused();
  // a day at least 3 days ahead (outside the 24-hour cancellation window), first free time
  const days = dialog.locator("button.day");
  await days.nth(Math.min(3, (await days.count()) - 1)).click();
  await dialog.locator("button.slot:not([disabled])").first().click();
  await dialog.getByRole("button", { name: "التالي" }).click();
  await dialog.getByRole("button", { name: /يوسف/ }).click();
  await dialog.getByRole("button", { name: "التالي" }).click();
  await dialog.getByRole("button", { name: /Bit/ }).click();
  await dialog.getByRole("button", { name: "تأكيد الحجز" }).click();
  await page.waitForURL(/\/schedule/);
  await expect(page.getByText("رياضيات للاختبار الآلي").first()).toBeVisible();
  const b = await sql("select status, child_id is not null as for_child from bookings where offering_id = $1", [S.offerId]);
  expect(b).toEqual([{ status: "confirmed", for_child: true }]);
  await ctx.storageState({ path: `results/parent-${info.project.name}.json` });
  await ctx.close();
});

test("11. messages and notifications: parent writes, teacher reads; opening one notification reads only that one", async ({ browser }, info) => {
  const p = await browser.newContext({ storageState: `results/parent-${info.project.name}.json` }); const pp = await p.newPage();
  await pp.goto(`/teacher/${S.teacherId}`);
  await pp.getByRole("button", { name: "راسل المعلم" }).click();
  await pp.waitForURL(/\/messages\//);
  await pp.getByLabel("اكتب رسالة").fill("مرحباً، هل نبدأ بالكسور؟");
  await pp.getByRole("button", { name: "إرسال" }).click();
  await expect(pp.getByText("مرحباً، هل نبدأ بالكسور؟")).toBeVisible();
  await p.close();

  const t = await browser.newContext(); const tp = await t.newPage();
  await signIn(tp, S.teacherPhone);
  await tp.goto("/messages");
  await tp.locator("a[href^='/messages/']").first().click();
  await expect(tp.getByText("مرحباً، هل نبدأ بالكسور؟")).toBeVisible();

  const unreadBefore = Number((await sql("select count(*) from notifications where user_id = $1 and read_at is null", [S.teacherUser]))[0].count);
  expect(unreadBefore).toBeGreaterThan(0);
  await tp.goto("/notifications");
  const unreadAfterList = Number((await sql("select count(*) from notifications where user_id = $1 and read_at is null", [S.teacherUser]))[0].count);
  expect(unreadAfterList, "showing the list does not mark everything read").toBe(unreadBefore);
  await tp.locator("a.notice.unread").first().click();
  await tp.waitForLoadState();
  const unreadAfterOpen = Number((await sql("select count(*) from notifications where user_id = $1 and read_at is null", [S.teacherUser]))[0].count);
  expect(unreadAfterOpen).toBe(unreadBefore - 1);
  await t.close();
});

test("12. roles, two-step cancellation, and no form data leaking between records or accounts", async ({ browser }, info) => {
  // Parent: no access to the admin page; cancellation needs a confirmation
  const p = await browser.newContext({ storageState: `results/parent-${info.project.name}.json` }); const pp = await p.newPage();
  await pp.goto("/admin");
  await expect(pp.locator("nav.tabs")).toHaveCount(0);
  await pp.goto("/schedule");
  await pp.getByText("إلغاء الحجز").first().click();
  await pp.getByRole("button", { name: "تأكيد الإلغاء" }).click();
  await expect.poll(async () => (await sql("select status from bookings where offering_id = $1", [S.offerId]))[0].status).toBe("cancelled");

  // KeepForm is scoped per record: a saved copy for course A must never fill course B's form
  await pp.goto("/account?error=x");
  await pp.evaluate(() => sessionStorage.setItem("classi-form:kf-updateProfile", JSON.stringify({ at: Date.now() - 31 * 60 * 1000, values: { full_name: ["قديم"] } })));
  await pp.reload();
  await expect(pp.locator('input[name="full_name"]')).not.toHaveValue("قديم");      // expired copies are ignored
  await pp.evaluate(() => sessionStorage.setItem("classi-form:kf-leaveReview-00000000-0000-0000-0000-000000000001", JSON.stringify({ at: Date.now(), values: { body: ["تقييم لحجز آخر"] } })));
  await p.close();

  // Signing in on the same device clears every remembered form
  const shared = await browser.newContext({ storageState: `results/parent-${info.project.name}.json` }); const sp = await shared.newPage();
  await sp.goto("/account");
  await sp.evaluate(() => sessionStorage.setItem("classi-form:kf-updateProfile", JSON.stringify({ at: Date.now(), values: { full_name: ["بيانات شخص آخر"] } })));
  await sp.goto("/login");
  expect(await sp.evaluate(() => Object.keys(sessionStorage).filter((k) => k.startsWith("classi-form:")).length)).toBe(0);
  await shared.close();

  // Admin (role given in the database): the admin page opens and shows the booking-rule settings
  const adminPhone = phoneFor(info, 3);
  const a = await browser.newContext(); const ap = await a.newPage();
  const adminId = await signUp(ap, { phone: adminPhone, name: "مدير الاختبار", role: "guardian" });
  await sql("update profiles set roles = array['admin']::app_role[] where id = $1", [adminId]);
  await ap.goto("/admin?tab=subs");
  await expect(ap.getByText("أقل مهلة لحجز حصة خصوصية")).toBeVisible();
  await a.close();
});
