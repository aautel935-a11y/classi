// Global setup for runs against the protected staging deployment: one request carrying Vercel's automation bypass
// secret in headers (never in a URL, so it stays out of logs and error messages) sets a bypass cookie for the
// staging host only; every test context starts from that state. The state file lives outside the test output folder.
import { request } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { BYPASS_STATE } from "./staging-state.mjs";

export default async function setup(config) {
  const base = config.projects[0].use.baseURL;
  const ctx = await request.newContext({
    baseURL: base,
    extraHTTPHeaders: { "x-vercel-protection-bypass": process.env.VERCEL_AUTOMATION_BYPASS_SECRET, "x-vercel-set-bypass-cookie": "true" },
  });
  const res = await ctx.get("/", { maxRedirects: 0 }).catch((e) => { throw new Error(`staging bypass request failed: ${e.name}`); });
  if (res.status() >= 400) throw new Error(`staging bypass failed: HTTP ${res.status()}`);
  const state = await ctx.storageState();
  if (!state.cookies.length) throw new Error("staging bypass: no cookie was set (check the bypass secret)");
  mkdirSync(dirname(BYPASS_STATE), { recursive: true });
  await ctx.storageState({ path: BYPASS_STATE });
  await ctx.dispose();
}
