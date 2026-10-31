// Accessibility (axe-core, WCAG 2 A/AA rules) on the main pages, phone and desktop. Serious and critical problems
// fail the test; the full list goes to the log. axe-core is installed in CI only (npm install --no-save axe-core).
import { test, expect } from "@playwright/test";
import { createRequire } from "node:module";
import { signUp, phoneFor, sql } from "./helpers.mjs";

const require = createRequire(import.meta.url);
let axePath = null;
try { axePath = require.resolve("axe-core/axe.min.js"); } catch { /* not installed: tests are skipped */ }

async function audit(page, label) {
  await page.addScriptTag({ path: axePath });
  const r = await page.evaluate(async () => {
    // eslint-disable-next-line no-undef
    const res = await axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
    return res.violations.map((v) => ({ id: v.id, impact: v.impact, n: v.nodes.length, help: v.help, target: v.nodes[0]?.target?.join(" ") }));
  });
  for (const v of r) console.log(`[axe] ${label} | ${v.impact} | ${v.id} x${v.n} | ${v.help} | ${v.target}`);
  if (!r.length) console.log(`[axe] ${label} | no violations`);
  return r.filter((v) => v.impact === "serious" || v.impact === "critical");
}

test.describe("accessibility (axe)", () => {
  test.skip(!axePath, "axe-core not installed");

  test("public pages: home, search, offer, teacher, login", async ({ page }, info) => {
    const offer = (await sql("select id from offerings where active and review_status = 'approved' and type = 'private' limit 1"))[0]?.id;
    const teacher = (await sql("select id from teachers where verify = 'verified' limit 1"))[0]?.id;
    const pages = [["/", "home"], ["/search", "search"], [`/offer/${offer}`, "offer"], [`/teacher/${teacher}`, "teacher"], ["/login", "login"]];
    const serious = [];
    for (const [url, label] of pages) {
      await page.goto(url, { waitUntil: "networkidle" });
      await page.waitForTimeout(2600); // the opening animation fades out first
      serious.push(...(await audit(page, `${info.project.name} ${label}`)).map((v) => `${label}: ${v.id}`));
    }
    expect(serious, serious.join(", ")).toEqual([]);
  });

  test("signed-in pages: account, schedule, notifications, messages", async ({ page }, info) => {
    await signUp(page, { phone: phoneFor(info, 7), name: "فحص الوصول", role: "guardian" });
    const serious = [];
    for (const [url, label] of [["/account", "account"], ["/schedule", "schedule"], ["/notifications", "notifications"], ["/messages", "messages"]]) {
      await page.goto(url, { waitUntil: "networkidle" });
      serious.push(...(await audit(page, `${info.project.name} ${label}`)).map((v) => `${label}: ${v.id}`));
    }
    expect(serious, serious.join(", ")).toEqual([]);
  });
});
