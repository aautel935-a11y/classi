// Minimal Next.js app: does the client apply a server action redirect? (diagnosis for Classi's E2E)
import { test, expect } from "@playwright/test";
for (const [btn, want] of [["same", "ok=1"], ["hash", "ok=2"], ["other", "r ok=3"]]) {
  test(`redirect from action: ${btn}`, async ({ page }) => {
    await page.goto("/", { waitUntil: "networkidle" });
    await page.getByRole("button", { name: btn, exact: true }).click();
    await expect(page.locator("#state")).toHaveText(want, { timeout: 15000 });
  });
}

for (const [path, btn] of [["/kf", "kf"], ["/sp", "sp"]]) {
  test(`redirect to the same page with search params: ${btn}`, async ({ page }) => {
    await page.goto(path, { waitUntil: "networkidle" });
    await page.getByRole("button", { name: btn, exact: true }).click();
    await expect(page.locator("#state")).toHaveText("ok=1", { timeout: 15000 });
  });
}
