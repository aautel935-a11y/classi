// Browser tests. They run against BASE_URL (CI: a production build on localhost with a local Supabase stack) and
// talk to that stack's database (E2E_DB_URL) only to read sign-in codes and to play the admin's part.
// Never point BASE_URL or E2E_DB_URL at production.
import { defineConfig, devices } from "@playwright/test";
import { resolve } from "node:path";

const base = process.env.BASE_URL || "http://localhost:3000";
if (/classi\.click/.test(base)) throw new Error("E2E must not run against production");
// A hosted target is allowed only for the staging project (classi-staging-*.vercel.app) with E2E_TARGET=staging.
if (/vercel\.app/.test(base) && !(process.env.E2E_TARGET === "staging" && /^https:\/\/classi-staging[a-z0-9-]*\.vercel\.app/.test(base)))
  throw new Error("hosted E2E runs only against the classi-staging project");
// Staging deployments are protected by Vercel Authentication: a global setup turns CI's automation bypass secret
// into a cookie for the staging host only (a header would also be sent to Supabase and break its CORS checks).
const bypass = !!process.env.VERCEL_AUTOMATION_BYPASS_SECRET;

export default defineConfig({
  testDir: ".",
  ...(bypass ? { globalSetup: "./staging-bypass.mjs" } : {}),
  outputDir: "results",
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  failOnFlakyTests: !!process.env.CI, // a retry may collect evidence, but a test that needed one fails the run
  reporter: [["list"], ["html", { outputFolder: "report", open: "never" }]],
  use: { baseURL: base, ...(bypass ? { storageState: resolve("results/staging-bypass.json") } : {}), locale: "ar", timezoneId: "Asia/Jerusalem", trace: "retain-on-failure", screenshot: "only-on-failure" },
  projects: [
    { name: "mobile", use: { ...devices["Pixel 7"] } },
    { name: "desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1280, height: 800 } } },
  ],
});
