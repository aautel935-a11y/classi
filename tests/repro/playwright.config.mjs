import { defineConfig, devices } from "@playwright/test";
export default defineConfig({ testDir: ".", testMatch: "repro.spec.mjs", timeout: 40000, workers: 1, reporter: "list",
  use: { baseURL: "http://localhost:3100" }, projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }] });
