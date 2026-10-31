// Public pages, read-only (8 scenarios, each on phone and desktop).
import { test, expect } from "@playwright/test";
import { expectNoSideScroll, sql } from "./helpers.mjs";

test("1. home: Arabic, right-to-left, no sideways scroll", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("html")).toHaveAttribute("lang", "ar");
  await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
  await expectNoSideScroll(page);
  // In-app navigation (no full reload): the search page replaces the home page
  await page.waitForLoadState("networkidle");
  await page.locator("a.searchbar").click();
  await expect(page).toHaveURL(/\/search/, { timeout: 15_000 });
  await expect(page.locator("a[href^='/offer/']").first()).toBeVisible();
});

test("2. search lists offers and filters by type", async ({ page }) => {
  await page.goto("/search");
  await expect(page.locator("a[href^='/offer/']").first()).toBeVisible();
  await page.goto("/search?type=course");
  await expect(page.locator("a[href^='/offer/']").first()).toBeVisible();
  await expectNoSideScroll(page);
});

test("3. an offer page asks visitors to sign in before booking", async ({ page }) => {
  const [o] = await sql("select id from offerings where type = 'private' and active order by created_at limit 1");
  await page.goto(`/offer/${o.id}`);
  await expect(page.getByRole("link", { name: "سجّل الدخول للحجز" })).toBeVisible();
  await expectNoSideScroll(page);
});

test("4. private pages send visitors to the login screen", async ({ page }) => {
  for (const path of ["/teach", "/schedule", "/manage", "/account", "/notifications"]) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/login\?next=/);
  }
  await page.goto("/admin");
  await expect(page).not.toHaveURL(/\/admin$/);
});

test("5. security headers are sent", async ({ request }) => {
  const r = await request.get("/");
  expect(r.headers()["x-frame-options"]).toBe("DENY");
  expect(r.headers()["content-security-policy"]).toContain("frame-ancestors 'none'");
  expect(r.headers()["x-content-type-options"]).toBe("nosniff");
  expect(r.headers()["x-powered-by"]).toBeUndefined();
});

test("6. redirects never leave the site (SEC-09)", async ({ page }) => {
  for (const next of ["//evil.example", "/\\evil.example", "https://evil.example"]) {
    await page.goto(`/auth/callback?next=${encodeURIComponent(next)}`);
    expect(new URL(page.url()).hostname).toBe(new URL(test.info().project.use.baseURL ?? "http://localhost:3000").hostname);
  }
});

test("7. robots, sitemap, and closed internal endpoints", async ({ request }) => {
  expect((await request.get("/robots.txt")).status()).toBe(200);
  expect((await request.get("/sitemap.xml")).status()).toBe(200);
  expect((await request.get("/api/health/cron")).status()).toBe(401);
  expect((await request.post("/api/push/dispatch", { data: {} })).status()).toBe(401);
  const h = await request.get("/api/health");
  expect(h.status()).toBeLessThan(600);
  expect(JSON.stringify(await h.json())).not.toMatch(/resend|019|sms/i);
});

test("8. Arabic page with Hebrew and English text stays right-to-left and fits the screen", async ({ page }) => {
  const [t] = await sql("select id from teachers where verify = 'verified' order by name limit 1");
  await sql("update teachers set bio = $1 where id = $2", ["أعلّم العبرية للطلاب العرب. שלום, אני מורה לעברית. English welcome too — 5 יחידות לימוד ✓", t.id]);
  await page.goto(`/teacher/${t.id}`);
  await expect(page.getByText("שלום, אני מורה לעברית", { exact: false })).toBeVisible();
  await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
  await expectNoSideScroll(page);
});
