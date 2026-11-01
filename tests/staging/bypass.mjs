// Global setup: one request to the staging host carrying Vercel's automation bypass secret in headers (never in a
// URL) sets a bypass cookie scoped to that host; every browser context starts from it. The secret itself is never
// given to the browser, so it cannot reach Supabase or any other host.
import { request } from "@playwright/test";
import { STAGING_HOST } from "./guard.mjs";

export default async function setup(config) {
  const statePath = config.projects[0].use.storageState;
  const ctx = await request.newContext({
    baseURL: `https://${STAGING_HOST}`,
    extraHTTPHeaders: { "x-vercel-protection-bypass": process.env.VERCEL_AUTOMATION_BYPASS_SECRET, "x-vercel-set-bypass-cookie": "true" },
  });
  const res = await ctx.get("/", { maxRedirects: 0 }).catch((e) => { throw new Error(`staging bypass request failed: ${e.name}`); });
  if (res.status() >= 400) throw new Error(`staging bypass failed: HTTP ${res.status()}`);
  const state = await ctx.storageState();
  if (!state.cookies.some((c) => c.domain.replace(/^\./, "") === STAGING_HOST)) throw new Error("staging bypass: no cookie for the staging host (check the secret)");
  // keep only cookies for the staging host
  state.cookies = state.cookies.filter((c) => c.domain.replace(/^\./, "") === STAGING_HOST);
  const { writeFileSync } = await import("node:fs");
  writeFileSync(statePath, JSON.stringify(state), { mode: 0o600 });
  await ctx.dispose();
}
