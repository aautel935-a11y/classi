// v3 ledger: staff permissions and isolation between institutes, through the real screens (local stack, synthetic
// accounts). The institutes, their staff link, an offer and a booking are set up in the LOCAL database (the tests play
// the admin's part); every ledger action goes through the browser, and what the screens hide is also tried directly
// at the database with the user's own session (it must be refused there too).
import { test, expect } from "@playwright/test";
import { db, localSql as sql, phoneFor, rpcAs, signUp } from "./helpers.mjs";

test.describe.configure({ mode: "serial" });

async function teacherProfile(page, bio) {
  await page.goto("/teach", { waitUntil: "networkidle" });
  await page.locator("#bio").fill(bio);
  await page.getByRole("button", { name: "حفظ الملف" }).click();
  await expect(page.locator("#hours")).toBeVisible({ timeout: 15_000 });
}
const newInstitute = async (name, owner) =>
  (await sql("insert into institutes (name, town, verify, owner_id) values ($1, 'باقة', 'verified', $2) returning id", [name, owner]))[0].id;

test("staff permissions and isolation between institutes", async ({ browser }, info) => {
  test.setTimeout(300_000);
  const tag = `${info.project.name} ${Date.now().toString(36)}`; // unique per attempt (a retry signs up again)
  const instName = `معهد السجل ${tag}`, otherName = `معهد آخر ${tag}`, custName = `زبونة المعهد ${tag}`;

  // ---------- people ----------
  const octx = await browser.newContext(); const op = await octx.newPage();
  const owner = await signUp(op, { phone: await phoneFor(info, 61), name: "صاحب المعهد", role: "institute" });
  const sctx = await browser.newContext(); const sp = await sctx.newPage();
  const staffUser = await signUp(sp, { phone: await phoneFor(info, 62), name: "موظف المعهد", role: "teacher" });
  await teacherProfile(sp, "أعمل في المعهد.");
  const staffTeacher = await db.teacherId(staffUser);
  const cctx = await browser.newContext(); const cp = await cctx.newPage();
  const customer = await signUp(cp, { phone: await phoneFor(info, 63), name: custName, role: "guardian" });
  const o2ctx = await browser.newContext(); const o2 = await o2ctx.newPage();
  const owner2 = await signUp(o2, { phone: await phoneFor(info, 64), name: "صاحب معهد آخر", role: "institute" });
  const xctx = await browser.newContext(); const xp = await xctx.newPage();
  await signUp(xp, { phone: await phoneFor(info, 65), name: "زبون لا علاقة له", role: "guardian" });

  // ---------- local fixtures: two institutes, the staff link, an offer, a booking ----------
  const inst = await newInstitute(instName, owner);
  const inst2 = await newInstitute(otherName, owner2);
  await sql("insert into institute_teachers (institute_id, teacher_id, status) values ($1, $2, 'accepted')", [inst, staffTeacher]);
  const offer = (await sql("insert into offerings (type, institute_id, title, price, course_teacher_id, review_status, active) values ('private', $1, 'درس اختبار السجل', 200, $2, 'approved', true) returning id", [inst, staffTeacher]))[0].id;
  await sql("insert into bookings (offering_id, booked_by, starts_at, status, price) values ($1, $2, now() + interval '2 hours', 'confirmed', 200)", [offer, customer]);

  // ---------- owner: the booking goes to the ledger, a deposit is recorded ----------
  let charge;
  await test.step("owner opens the booking in the ledger and records a deposit", async () => {
    await op.goto("/manage", { waitUntil: "networkidle" });
    await op.locator(".card").filter({ hasText: custName }).getByRole("button", { name: /سجل المستحقات/ }).click();
    await expect(op.getByText("أُضيف المستحق.")).toBeVisible();
    charge = (await sql("select id from charges where institute_id = $1 and customer_id = $2", [inst, customer]))[0]?.id;
    expect(charge).toBeTruthy();
    const card = op.locator(".card").filter({ hasText: custName }).first();
    await card.getByRole("link", { name: "الدفعات والتفاصيل" }).click();
    const pay = op.locator("form").filter({ has: op.locator('select[name="method"]') });
    await pay.locator('select[name="kind"]').selectOption("deposit");
    await pay.locator('input[name="amount"]').fill("50");
    await pay.locator('select[name="method"]').selectOption("cash");
    await pay.getByRole("button", { name: "تسجيل" }).click();
    await expect(op.getByText("سُجّلت الدفعة.")).toBeVisible();
  });
  const ownerEntry = (await sql("select id from payments where charge_id = $1 and kind = 'deposit'", [charge]))[0].id;

  // ---------- staff without permission ----------
  await test.step("staff without permission: no institute ledger, refused at the database", async () => {
    await sp.goto(`/ledger?b=i:${inst}`, { waitUntil: "networkidle" });
    await expect(sp.getByText(custName)).toHaveCount(0);
    await expect(sp.getByRole("link", { name: new RegExp(instName) })).toHaveCount(0);
    const r = await rpcAs(sctx, "record_payment", { p_charge: charge, p_kind: "payment", p_amount: 10, p_method: "cash" });
    expect(r.status).toBeGreaterThanOrEqual(400);
    const list = await rpcAs(sctx, "business_charges", { p_teacher: null, p_institute: inst, p_status: null });
    expect(list.body).toEqual([]);
  });

  // ---------- owner grants "record" only ----------
  await test.step("owner grants the staff member 'record payments'", async () => {
    await op.goto("/ledger", { waitUntil: "networkidle" });
    const staffBox = op.locator("details").filter({ hasText: "صلاحيات الطاقم في السجل" });
    await staffBox.locator("summary").click();
    const row = staffBox.locator(".row").filter({ hasText: "موظف المعهد" });
    await row.getByRole("button", { name: "تسجيل الدفعات" }).click();
    await expect(op.getByText("حُدّثت صلاحيات الطاقم.")).toBeVisible();
    expect((await sql("select array_agg(permission)::text p from staff_permissions where institute_id = $1 and teacher_id = $2", [inst, staffTeacher]))[0].p).toBe("{payments.record}");
  });

  await test.step("staff with 'record': records and corrects only their own entry; no adjust, cancel, report", async () => {
    await sp.goto(`/ledger?b=i:${inst}`, { waitUntil: "networkidle" });
    const card = sp.locator(".card").filter({ hasText: custName }).first();
    await expect(card).toBeVisible();
    await card.getByRole("link", { name: "الدفعات والتفاصيل" }).click();
    await expect(sp.locator("summary", { hasText: "تعديل المبلغ أو الإلغاء" })).toHaveCount(0);
    await expect(sp.getByRole("link", { name: /تصدير CSV/ })).toHaveCount(0);
    const pay = sp.locator("form").filter({ has: sp.locator('select[name="method"]') });
    await pay.locator('select[name="kind"]').selectOption("payment");
    await pay.locator('input[name="amount"]').fill("30");
    await pay.locator('select[name="method"]').selectOption("paybox");
    await pay.getByRole("button", { name: "تسجيل" }).click();
    await expect(sp.getByText("سُجّلت الدفعة.")).toBeVisible();

    // the owner's deposit: the screen offers the correction, the database refuses it for this staff member
    const dep = sp.locator(".card .card").filter({ hasText: "عربون" }).first();
    await dep.locator("summary", { hasText: "تصحيح هذه الدفعة" }).click();
    await dep.locator('input[name="reason"]').fill("ليست لي");
    await dep.getByRole("button", { name: /إلغاء هذه الدفعة/ }).click();
    await expect(sp.locator("p.err")).toContainText("ليست لديك صلاحية تصحيح هذه الدفعة");
    expect((await sql("select count(*)::int n from payments where voids = $1", [ownerEntry]))[0].n).toBe(0);

    // their own entry, within 24 hours: allowed
    const mine = sp.locator(".card .card").filter({ hasText: "PayBox" }).first();
    await mine.locator("summary", { hasText: "تصحيح هذه الدفعة" }).click();
    await mine.locator('input[name="reason"]').fill("المبلغ خطأ");
    await mine.getByRole("button", { name: /إلغاء هذه الدفعة/ }).click();
    await expect(sp.getByText(/سُجّل التصحيح/)).toBeVisible();

    // what the screen does not offer is refused at the database and the export route
    for (const [fn, args] of [
      ["cancel_charge", { p_charge: charge, p_reason: "إلغاء من الموظف" }],
      ["adjust_charge", { p_charge: charge, p_amount: 1, p_due_on: null, p_reason: "خصم من الموظف" }],
      ["record_payment", { p_charge: charge, p_kind: "refund", p_amount: 10, p_method: "cash" }],
      ["ledger_report", { p_from: "2026-01-01", p_to: "2026-12-31", p_teacher: null, p_institute: inst }],
      ["set_staff_permission", { p_institute: inst, p_teacher: staffTeacher, p_permission: "payments.correct", p_on: true }],
    ]) {
      const r = await rpcAs(sctx, fn, args);
      expect(r.status, `${fn} must be refused for staff with 'record' only`).toBeGreaterThanOrEqual(400);
    }
    expect((await sctx.request.get(`/ledger/export?b=i:${inst}`)).status()).toBe(403);
    const c = (await sql("select amount::text, cancelled_at from charges where id = $1", [charge]))[0];
    expect(c).toEqual({ amount: "200.00", cancelled_at: null });
  });

  // ---------- isolation: another institute, an unrelated customer ----------
  await test.step("another institute sees nothing of this one", async () => {
    await o2.goto("/ledger", { waitUntil: "networkidle" });
    await expect(o2.getByText(custName)).toHaveCount(0);
    await o2.goto(`/ledger?b=i:${inst}`, { waitUntil: "networkidle" });
    await expect(o2.getByText(custName)).toHaveCount(0);
    expect((await o2ctx.request.get(`/ledger/export?b=i:${inst}`)).status()).toBe(403);
    expect((await rpcAs(o2ctx, "business_charges", { p_teacher: null, p_institute: inst, p_status: null })).body).toEqual([]);
    expect((await rpcAs(o2ctx, "charge_entries", { p_charge: charge })).body).toEqual([]);
    expect((await rpcAs(o2ctx, "record_payment", { p_charge: charge, p_kind: "payment", p_amount: 1, p_method: "cash" })).status).toBeGreaterThanOrEqual(400);
    expect((await rpcAs(o2ctx, "set_staff_permission", { p_institute: inst, p_teacher: staffTeacher, p_permission: "payments.correct", p_on: true })).status).toBeGreaterThanOrEqual(400);
    // and it cannot put a debt in this institute's customer's account (no booking with institute 2)
    const r = await rpcAs(o2ctx, "create_charge", { p_teacher: null, p_institute: inst2, p_customer_label: "x", p_description: "y", p_amount: 10, p_customer: customer });
    expect(r.status).toBeGreaterThanOrEqual(400);
    expect(JSON.stringify(r.body)).toContain("غير مرتبط بنشاطك");
  });

  await test.step("the customer sees her charge with the notice; an unrelated customer sees none", async () => {
    await cp.goto("/account", { waitUntil: "networkidle" });
    const box = cp.locator("#charges");
    await expect(box).toContainText(instName);
    await expect(box).toContainText("Classi لا يستلم الأموال");
    await expect(box).toContainText("مدفوع جزئياً");
    await expect(box.getByRole("button")).toHaveCount(0);   // read only
    await xp.goto("/account", { waitUntil: "networkidle" });
    await expect(xp.locator("#charges")).toHaveCount(0);
    expect((await rpcAs(xctx, "my_charges", {})).body).toEqual([]);
  });

  await test.step("owner revokes: the staff member loses the ledger at once", async () => {
    await op.goto("/ledger", { waitUntil: "networkidle" });
    const staffBox = op.locator("details").filter({ hasText: "صلاحيات الطاقم في السجل" });
    await staffBox.locator("summary").click();
    await staffBox.locator(".row").filter({ hasText: "موظف المعهد" }).getByRole("button", { name: "تسجيل الدفعات" }).click();
    await expect(op.getByText("حُدّثت صلاحيات الطاقم.")).toBeVisible();
    await sp.goto(`/ledger?b=i:${inst}`, { waitUntil: "networkidle" });
    await expect(sp.getByText(custName)).toHaveCount(0);
    expect((await rpcAs(sctx, "business_charges", { p_teacher: null, p_institute: inst, p_status: null })).body).toEqual([]);
  });

  for (const c of [octx, sctx, cctx, o2ctx, xctx]) await c.close();
});
