// v3 customer payments ledger through the real screens (local stack, synthetic accounts):
// a teacher records a charge, a deposit, a payment and a documented correction; the CSV carries the notice;
// another account sees nothing of it; payments cannot be edited even directly in the database.
import { test, expect } from "@playwright/test";
import { db, expectNoSideScroll, localSql, phoneFor, signUp } from "./helpers.mjs";

test.describe.configure({ mode: "serial" });

test("ledger: charge, deposit, payment, correction, export, isolation", async ({ browser }, info) => {
  const ctx = await browser.newContext(); const page = await ctx.newPage();
  const phone = await phoneFor(info, 41);
  const user = await signUp(page, { phone, name: "حرفي السجل", role: "teacher" });
  await page.goto("/teach", { waitUntil: "networkidle" });
  await page.locator("#bio").fill("أصلح الأقفال وأنسخ المفاتيح.");
  await page.getByRole("button", { name: "حفظ الملف" }).click();
  await expect(page.locator("#hours")).toBeVisible({ timeout: 15_000 });
  const teacher = await db.teacherId(user);
  expect(teacher).toBeTruthy();

  // the link from the payments section leads to the ledger
  await page.goto("/ledger", { waitUntil: "networkidle" });
  await expect(page.getByRole("heading", { name: "سجل المستحقات" })).toBeVisible();
  await expect(page.getByText(/Classi لا يستلم الأموال/).first()).toBeVisible();

  // 1. new charge 300 with a 50 deposit
  const form = page.locator("form").filter({ has: page.locator('input[name="customer"]') });
  await form.locator('input[name="customer"]').fill("زبون الاختبار");
  await form.locator('input[name="description"]').fill("تبديل قفل باب");
  await form.locator('input[name="amount"]').fill("300");
  await form.locator('input[name="deposit"]').fill("50");
  await form.getByRole("button", { name: "إضافة" }).click();
  await expect(page.getByText("أُضيف المستحق.")).toBeVisible();
  const card = page.locator(".card").filter({ hasText: "زبون الاختبار" }).first();
  await expect(card.getByText("غير مدفوع", { exact: true })).toBeVisible();

  // 2. deposit (the form suggests the deposit amount first)
  await card.getByRole("link", { name: "الدفعات والتفاصيل" }).click();
  const pay = page.locator("form").filter({ has: page.locator('select[name="method"]') });
  await expect(pay.locator('input[name="amount"]')).toHaveValue("50");
  await pay.locator('select[name="method"]').selectOption("bit");
  await pay.getByRole("button", { name: "تسجيل" }).click();
  await expect(page.getByText("سُجّلت الدفعة.")).toBeVisible();
  await expect(page.locator(".card").filter({ hasText: "زبون الاختبار" }).first().getByText("مدفوع جزئياً", { exact: true })).toBeVisible();

  // 3. the rest in cash → paid
  const pay2 = page.locator("form").filter({ has: page.locator('select[name="method"]') });
  await pay2.locator('select[name="kind"]').selectOption("payment");
  await pay2.locator('input[name="amount"]').fill("250");
  await pay2.locator('select[name="method"]').selectOption("cash");
  await pay2.getByRole("button", { name: "تسجيل" }).click();
  await expect(page.getByText("سُجّلت الدفعة.")).toBeVisible();
  await expect(page.locator(".card").filter({ hasText: "زبون الاختبار" }).first().getByText("مدفوع", { exact: true })).toBeVisible();

  // 4. documented correction of the cash entry: the original stays visible, the charge is partial again
  const cashEntry = page.locator(".card").filter({ hasText: "نقداً" }).filter({ hasText: "250" }).first();
  await cashEntry.locator("summary", { hasText: "تصحيح هذه الدفعة" }).click();
  await cashEntry.locator('input[name="reason"]').fill("سُجّلت بالخطأ");
  await cashEntry.getByRole("button", { name: /إلغاء هذه الدفعة/ }).click();
  await expect(page.getByText(/سُجّل التصحيح/)).toBeVisible();
  await expect(page.getByText(/أُلغيت بتصحيح: سُجّلت بالخطأ/)).toBeVisible();
  await expect(page.locator(".card").filter({ hasText: "زبون الاختبار" }).first().getByText("مدفوع جزئياً", { exact: true })).toBeVisible();
  if (info.project.name === "mobile") await expectNoSideScroll(page);

  // 5. database: two money entries + one void, and no UPDATE/DELETE even for the database owner
  const rows = await localSql(
    "select p.kind, p.amount::text from payments p join charges c on c.id = p.charge_id where c.teacher_id = $1 order by p.recorded_at", [teacher]);
  expect(rows.map((r) => `${r.kind}:${r.amount}`)).toEqual(["deposit:50.00", "payment:250.00", "void:250.00"]);
  await expect(localSql("update payments set amount = 1 where charge_id in (select id from charges where teacher_id = $1)", [teacher])).rejects.toThrow();
  await expect(localSql("delete from payments where charge_id in (select id from charges where teacher_id = $1)", [teacher])).rejects.toThrow();

  // 6. CSV export for the accountant: the notice first, formula-safe
  const csv = await page.request.get(`/ledger/export?b=t:${teacher}`);
  expect(csv.status()).toBe(200);
  expect(csv.headers()["content-type"]).toContain("text/csv");
  const text = await csv.text();
  expect(text).toContain("Classi لا يستلم الأموال");
  expect(text).toContain("زبون الاختبار");

  // 7. another account: no ledger, no export, nothing of this business
  const ctx2 = await browser.newContext(); const other = await ctx2.newPage();
  await signUp(other, { phone: await phoneFor(info, 42), name: "ولي أمر آخر", role: "guardian" });
  await other.goto("/ledger", { waitUntil: "networkidle" });
  await expect(other.getByText(/هذا السجل لأصحاب الأعمال/)).toBeVisible();
  await expect(other.getByText("زبون الاختبار")).toHaveCount(0);
  const denied = await other.request.get(`/ledger/export?b=t:${teacher}`);
  expect(denied.status()).toBe(403);
  const anon = await (await browser.newContext()).request.get(`/ledger/export?b=t:${teacher}`);
  expect(anon.status()).toBe(401);
  await ctx2.close(); await ctx.close();
});
