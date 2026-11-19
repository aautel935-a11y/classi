// v3 business access through the real screens (local stack, synthetic accounts).
// Admin: launch date, trial days, grace days, trial extension, exemption, discount — and a non-admin refused, on the
// page and directly at the database. Owner: days left, warning near the end, reminder, grace, expiry that hides but
// keeps everything, renewal that brings it back.
// The tests play the clock by moving the trial end in the LOCAL database, and put every setting back at the end.
import { test, expect } from "@playwright/test";
import { dayIL, db, localSql as sql, phoneFor, rpcAs, signUp } from "./helpers.mjs";

test.describe.configure({ mode: "serial" });

async function resetAccess() {
  await sql("update app_settings set value = 'false' where key = 'subscriptions_required'");
  await sql("insert into app_settings (key, value) values ('launch_at', ''), ('trial_days', '30'), ('grace_days', '7') on conflict (key) do update set value = excluded.value");
  await sql("delete from business_exemptions");
  await sql("delete from business_trials");
}
const setTrialEnd = (teacher, interval) => sql(`update business_trials set ends_at = now() + $2::interval where teacher_id = $1`, [teacher, interval]);
const state = async (teacher) => (await sql("select state, days_left from business_access_state($1, null)", [teacher]))[0];

test("subscriptions: admin settings and actions, owner trial, warning, grace, expiry, renewal", async ({ browser }, info) => {
  test.setTimeout(300_000);
  await resetAccess();
  try {
    // ---------- a teacher (created before launch) and an admin ----------
    const tctx = await browser.newContext(); const tp = await tctx.newPage();
    const tName = `حرفي الاشتراك ${info.project.name}`;
    const tUser = await signUp(tp, { phone: await phoneFor(info, 51), name: tName, role: "teacher" });
    await tp.goto("/teach", { waitUntil: "networkidle" });
    await tp.locator("#bio").fill("أفتح الأقفال وأنسخ المفاتيح، بياناتي يجب أن تبقى.");
    await tp.getByRole("button", { name: "حفظ الملف" }).click();
    await expect(tp.locator("#hours")).toBeVisible({ timeout: 15_000 });
    const teacher = await db.teacherId(tUser);
    await db.verifyTeacher(teacher);
    expect((await state(teacher)).state).toBe("prelaunch");

    const actx = await browser.newContext(); const ap = await actx.newPage();
    const aUser = await signUp(ap, { phone: await phoneFor(info, 52), name: "مدير الاشتراكات", role: "guardian" });
    await db.makeAdmin(aUser);

    // ---------- non-admin refused, on the page and at the database ----------
    await test.step("a non-admin cannot open or call the admin actions", async () => {
      await tp.goto("/admin?tab=subs");
      await expect(tp.getByRole("heading", { name: "هذه الصفحة للمدير فقط" })).toBeVisible();
      for (const [fn, args] of [
        ["admin_set_setting", { p_key: "trial_days", p_value: "90" }],
        ["admin_extend_trial", { p_teacher: teacher, p_institute: null, p_days: 30, p_reason: "لنفسي" }],
        ["admin_set_exemption", { p_teacher: teacher, p_institute: null, p_until: dayIL(300), p_reason: "لنفسي" }],
        ["admin_upsert_plan", { p_code: "free", p_name: "مجاني", p_months: 12, p_price: 0, p_active: true, p_sort: 0 }],
      ]) {
        const r = await rpcAs(tctx, fn, args);
        expect(r.status, `${fn} must be refused`).toBeGreaterThanOrEqual(400);
        expect(JSON.stringify(r.body)).toContain("للمدير فقط");
      }
      expect((await sql("select value from app_settings where key = 'trial_days'"))[0].value).toBe("30");
      expect((await sql("select count(*)::int n from business_exemptions"))[0].n).toBe(0);
    });

    // ---------- admin: trial 14, grace 5, launch 10 days ago ----------
    // every admin action starts from a clean page (no flash from the previous one) and waits for its own flash
    const done = async () => { await expect(ap.locator(".okmsg")).toHaveText("تم."); await expect(ap.locator("p.err")).toHaveCount(0); };
    const setting = async (key, value) => {
      await ap.goto("/admin?tab=subs", { waitUntil: "networkidle" });
      const f = ap.locator("form").filter({ has: ap.locator(`input[name="key"][value="${key}"]`) });
      await f.locator('input[name="value"]').fill(value);
      await f.getByRole("button", { name: "حفظ" }).click();
      await done();
      expect((await sql("select value from app_settings where key = $1", [key]))[0].value).toBe(value);
    };
    await test.step("admin sets trial days, grace days and the launch date", async () => {
      await ap.goto("/admin?tab=subs", { waitUntil: "networkidle" });
      await expect(ap.getByRole("heading", { name: "التجربة المجانية والوصول" })).toBeVisible();
      await setting("trial_days", "14");
      await setting("grace_days", "5");
      await setting("launch_at", dayIL(-10));
      expect(await state(teacher)).toEqual({ state: "trial", days_left: 4 });
    });

    const card = () => ap.locator(".card").filter({ hasText: tName }).filter({ has: ap.locator('input[name="op"][value="extend"]') });
    await test.step("admin extends the trial by 10 days", async () => {
      await ap.goto("/admin?tab=subs", { waitUntil: "networkidle" });
      await expect(card().getByText(/تجربة مجانية · 4 يوم/)).toBeVisible();
      await card().locator("summary", { hasText: "تمديد التجربة أو إعفاء" }).click();
      const f = card().locator("form").filter({ has: ap.locator('input[name="op"][value="extend"]') });
      await f.locator('input[name="days"]').fill("10");
      await f.locator('input[name="reason"]').fill("تأخر الإعداد");
      await f.getByRole("button", { name: "تمديد" }).click();
      await done();
      expect(await state(teacher)).toEqual({ state: "trial", days_left: 14 });
      expect((await sql("select count(*)::int n from audit_log where action = 'trial_extend' and teacher_id = $1 and reason = 'تأخر الإعداد'", [teacher]))[0].n).toBe(1);
    });

    await test.step("admin grants an exemption, then revokes it", async () => {
      await ap.goto("/admin?tab=subs", { waitUntil: "networkidle" });
      await card().locator("summary", { hasText: "تمديد التجربة أو إعفاء" }).click();
      const f = card().locator("form").filter({ has: ap.locator('input[name="op"][value="exempt"]') });
      await f.locator('input[name="until"]').fill(dayIL(30));
      await f.locator('input[name="reason"]').fill("شريك تجريبي");
      await f.getByRole("button", { name: "حفظ الإعفاء" }).click();
      await done();
      expect((await state(teacher)).state).toBe("exempt");
      await expect(card().getByText(/معفى/).first()).toBeVisible();
      await ap.goto("/admin?tab=subs", { waitUntil: "networkidle" });
      await card().locator("summary", { hasText: "تمديد التجربة أو إعفاء" }).click();
      const g = card().locator("form").filter({ has: ap.locator('input[name="op"][value="exempt"]') });
      await g.locator('input[name="reason"]').fill("انتهت الشراكة");
      await g.getByRole("button", { name: "حفظ الإعفاء" }).click();
      await done();
      expect((await state(teacher)).state).toBe("trial");
    });

    // ---------- owner: days left and the warning near the end ----------
    await test.step("owner sees the days left of the trial", async () => {
      await tp.goto("/teach", { waitUntil: "networkidle" });
      await expect(tp.getByText(/تجربتك المجانية في Classi حتى/)).toBeVisible();
      await expect(tp.getByText(/بقي 14 أيام/)).toBeVisible();
    });
    await test.step("near the end: a warning on the page and a reminder", async () => {
      await setTrialEnd(teacher, "2 days 22 hours");
      await tp.goto("/teach", { waitUntil: "networkidle" });
      const banner = tp.locator(".note.sub-warn").filter({ hasText: "تجربتك المجانية" });
      await expect(banner).toBeVisible();
      await expect(banner).toContainText("بقي 3 أيام");
      await sql("update app_settings set value = 'true' where key = 'subscriptions_required'");
      await sql("select subscription_reminders()");
      await tp.goto("/notifications", { waitUntil: "networkidle" });
      await expect(tp.getByText(/تجربتك المجانية في Classi تنتهي خلال 3 أيام/)).toBeVisible();
    });

    // ---------- a subscription request, discounted by the admin ----------
    await test.step("admin discounts the owner's open request", async () => {
      await sql("insert into subscriptions (teacher_id, plan_code, months, price) values ($1, 'm1', 1, 170)", [teacher]);
      await ap.goto("/admin?tab=subs", { waitUntil: "networkidle" });
      const req = ap.locator(".card").filter({ hasText: tName }).filter({ has: ap.locator('input[name="op"][value="activate"]') });
      await req.locator("summary", { hasText: "خصم" }).click();
      await req.locator('input[name="price"]').fill("120");
      await req.locator('input[name="reason"]').fill("عرض الإطلاق");
      await req.getByRole("button", { name: "حفظ الخصم" }).click();
      await done();
      const s = (await sql("select list_price, price, discount_reason from subscriptions where teacher_id = $1 and status = 'pending'", [teacher]))[0];
      expect(s).toEqual({ list_price: 170, price: 120, discount_reason: "عرض الإطلاق" });
    });

    // ---------- grace, then expiry: hidden from customers, nothing deleted ----------
    const visitor = await browser.newContext();
    const publicStatus = async () => (await visitor.request.get(`/teacher/${teacher}`)).status();
    await test.step("grace period: still visible, the owner is warned", async () => {
      await setTrialEnd(teacher, "-2 days");
      expect((await state(teacher)).state).toBe("grace");
      await tp.goto("/teach", { waitUntil: "networkidle" });
      await expect(tp.getByText(/أنت في فترة سماح/)).toBeVisible();
      expect(await publicStatus()).toBe(200);
    });
    await test.step("expired: hidden from customers, the owner's data kept", async () => {
      await setTrialEnd(teacher, "-10 days");
      expect((await state(teacher)).state).toBe("expired");
      expect(await publicStatus()).toBe(404);
      await tp.goto("/teach", { waitUntil: "networkidle" });
      await expect(tp.getByText("لا يوجد اشتراك فعّال")).toBeVisible();
      await expect(tp.locator("#bio")).toHaveValue(/بياناتي يجب أن تبقى/);
      expect((await sql("select count(*)::int n from teachers where id = $1 and user_id = $2", [teacher, tUser]))[0].n).toBe(1);
    });

    // ---------- renewal: the admin confirms the transfer ----------
    await test.step("renewal brings everything back", async () => {
      await ap.goto("/admin?tab=subs", { waitUntil: "networkidle" });
      const req = ap.locator(".card").filter({ hasText: tName }).filter({ has: ap.locator('input[name="op"][value="activate"]') });
      await req.getByRole("button", { name: "وصل المبلغ، فعّل" }).click();
      await done();
      expect((await state(teacher)).state).toBe("active");
      expect(await publicStatus()).toBe(200);
      await tp.goto("/teach", { waitUntil: "networkidle" });
      await expect(tp.getByText(/الاشتراك فعّال حتى/)).toBeVisible();
    });
    await visitor.close(); await actx.close(); await tctx.close();
  } finally {
    await resetAccess();
  }
});
