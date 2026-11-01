// Hosted STAGING browser tests (classi-staging on Vercel + the classi-staging Supabase project).
// UI and Supabase Auth only: no database connection, no service keys. Run by .github/workflows/staging.yml.
// Nothing that could hold a code, a cookie or a session is kept: no traces, screenshots, videos or HTML report.
import { defineConfig, devices } from "@playwright/test";
import { checkStagingEnv, DRY_RUN, TARGET } from "./guard.mjs";

checkStagingEnv();

export default defineConfig({
  testDir: ".",
  ...(DRY_RUN ? {} : { globalSetup: "./bypass.mjs" }),
  outputDir: process.env.RUNNER_TEMP ? `${process.env.RUNNER_TEMP}/staging-results` : "/tmp/staging-results",
  timeout: 90_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"]],
  use: {
    baseURL: TARGET.base,
    ...(DRY_RUN ? {} : { storageState: (process.env.RUNNER_TEMP || "/tmp") + "/classi-staging-bypass.json" }),
    locale: "ar", timezoneId: "Asia/Jerusalem",
    trace: "off", screenshot: "off", video: "off",
  },
  projects: [
    { name: "mobile", use: { ...devices["Pixel 7"] } },
    { name: "desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1280, height: 800 } } },
  ],
});
