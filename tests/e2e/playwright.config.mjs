// LOCAL browser tests. They run against BASE_URL (CI: a production build on localhost with a local Supabase stack)
// and talk to that stack's database (E2E_DB_URL) only to read sign-in codes and to play the admin's part.
// Hosted targets are refused: the hosted staging suite is tests/staging (no database access at all).
import { defineConfig, devices } from "@playwright/test";

const base = process.env.BASE_URL || "http://localhost:3000";
if (!/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/?$/.test(base)) throw new Error("local E2E runs only against localhost (staging: tests/staging)");

export default defineConfig({
  testDir: ".",
  outputDir: "results",
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  failOnFlakyTests: !!process.env.CI, // a retry may collect evidence, but a test that needed one fails the run
  reporter: [["list"], ["html", { outputFolder: "report", open: "never" }]],
  use: { baseURL: base, locale: "ar", timezoneId: "Asia/Jerusalem", trace: "retain-on-failure", screenshot: "only-on-failure" },
  projects: [
    { name: "mobile", use: { ...devices["Pixel 7"] } },
    { name: "desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1280, height: 800 } } },
  ],
});
