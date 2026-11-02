// Global setup: one request to the staging host carrying Vercel's automation bypass secret in headers (never in a
// URL) sets a bypass cookie scoped to that host; every browser context starts from it. The secret itself is never
// given to the browser, so it cannot reach Supabase or any other host.
// Also a small command for the Lighthouse step: `node tests/staging/bypass.mjs --cookie-file <path>` writes only the
// resulting Cookie header (mode 600) for the staging host. Nothing secret is printed in either case.
import { request } from "@playwright/test";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { STAGING_HOST, cleanStagingSecrets, shapeOf } from "./guard.mjs";

const forStaging = (c) => c.domain.replace(/^\./, "") === STAGING_HOST;

/** Asks the staging host for the bypass cookie. Returns the storage state with staging cookies only. */
export async function stagingBypassState() {
  cleanStagingSecrets(process.env);
  const secret = process.env.VERCEL_AUTOMATION_BYPASS_SECRET ?? "";
  if (!secret) throw new Error("staging bypass: VERCEL_AUTOMATION_BYPASS_SECRET is empty or not passed to this step");
  const ctx = await request.newContext({
    baseURL: `https://${STAGING_HOST}`,
    extraHTTPHeaders: { "x-vercel-protection-bypass": secret, "x-vercel-set-bypass-cookie": "true" },
  });
  try {
    const res = await ctx.get("/", { maxRedirects: 0 }).catch((e) => { throw new Error(`staging bypass request failed: ${e.name}`); });
    const state = await ctx.storageState();
    const cookies = state.cookies.filter(forStaging);
    if (res.status() >= 400 || !cookies.length) {
      // what Vercel answered, without anything secret: status, where it redirects (host only), cookie names
      const loc = res.headers().location;
      const where = loc ? new URL(loc, `https://${STAGING_HOST}`).host : "none";
      const names = res.headersArray().filter((h) => h.name.toLowerCase() === "set-cookie").map((h) => h.value.split("=")[0]);
      throw new Error(`staging bypass refused: HTTP ${res.status()}, redirect to ${where}, cookies set: ${names.join(", ") || "none"}; `
        + `secret seen: ${shapeOf(secret)}. A refusal (401, or a redirect to vercel.com) means the GitHub secret is not one of `
        + `classi-staging's Protection Bypass for Automation secrets`);
    }
    state.cookies = cookies;
    return state;
  } finally { await ctx.dispose(); }
}

export default async function setup(config) {
  const state = await stagingBypassState();
  writeFileSync(config.projects[0].use.storageState, JSON.stringify(state), { mode: 0o600 });
  console.log(`[staging-bypass] ok: ${state.cookies.length} cookie(s) for ${STAGING_HOST}`);
}

// command line (Lighthouse step)
if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const i = process.argv.indexOf("--cookie-file");
  const file = i > 0 ? process.argv[i + 1] : "";
  if (!file) { console.error("usage: node tests/staging/bypass.mjs --cookie-file <path>"); process.exit(2); }
  stagingBypassState().then((state) => {
    writeFileSync(file, state.cookies.map((c) => `${c.name}=${c.value}`).join("; "), { mode: 0o600 });
    console.log(`[staging-bypass] ok: ${state.cookies.length} cookie(s) for ${STAGING_HOST}`);
  }).catch((e) => { console.log(`::error::${e.message}`); process.exit(1); });   // stdout: GitHub reads annotations there
}
