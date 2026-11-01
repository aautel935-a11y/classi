// Global setup for runs against the protected staging deployment: one visit with Vercel's automation bypass
// secret sets a bypass cookie for the staging host; every test context starts from that state.
import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

export default async function setup(config) {
  const base = config.projects[0].use.baseURL;
  const secret = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;
  const browser = await chromium.launch();
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  const url = new URL("/", base);
  url.searchParams.set("x-vercel-protection-bypass", secret);
  url.searchParams.set("x-vercel-set-bypass-cookie", "true");
  const res = await page.goto(url.toString());
  if (!res || res.status() >= 400) throw new Error(`staging bypass failed: HTTP ${res?.status()}`);
  mkdirSync(resolve("results"), { recursive: true });
  await ctx.storageState({ path: resolve("results/staging-bypass.json") });
  await browser.close();
}
