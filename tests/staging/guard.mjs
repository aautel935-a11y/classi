// Safety checks for the hosted STAGING suite. Imported by the config, so a wrong setting stops the run before any
// browser starts. The suite has no database access at all: it works through the app and Supabase Auth only.
export const STAGING_HOST = "classi-staging.vercel.app";
export const STAGING_SUPABASE_HOST = "nfipmylyahhogykikuqo.supabase.co";
// Hosts the browser must never reach during a staging run (production app and production database).
export const FORBIDDEN_HOSTS = [/(^|\.)classi\.click$/i, /rfxhqcagdsuhkjzwbawx/i];

/** CI dry run (STAGING_DRY_RUN=1): the same suite against the local stack in CI, with the same five accounts and
 * fixed codes (supabase/config.toml), to prove the journeys before a real staging run. Never a hosted target. */
export const DRY_RUN = process.env.STAGING_DRY_RUN === "1";
export const TARGET = DRY_RUN
  ? { base: "http://localhost:3000", appHost: "localhost", supabaseHost: "127.0.0.1" }
  : { base: `https://${STAGING_HOST}`, appHost: STAGING_HOST, supabaseHost: STAGING_SUPABASE_HOST };

export const OTP_VARS = ["TEACHER", "INSTITUTE", "PARENT", "STUDENT", "ADMIN"].map((r) => `STAGING_OTP_${r}`);
// Characters a copy-paste can add to a secret without anyone seeing them: spaces and newlines, no-break and
// zero-width spaces, left-to-right / right-to-left marks and embeddings (common on an Arabic keyboard), BOM.
const INVISIBLE = /[\s ​-‏‪-‮⁠⁦-⁩﻿]/g;
const toAsciiDigits = (s) => s.replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))   // ٠-٩
  .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06F0));                               // ۰-۹

/** The shape of a value, never the value: its length and which kinds of characters it holds. */
export function shapeOf(v = "") {
  const n = (re) => (v.match(re) || []).length;
  const parts = [`length ${[...v].length}`, `digits 0-9: ${n(/[0-9]/g)}`];
  const arabic = n(/[٠-٩۰-۹]/g), space = n(/[\s ]/g), marks = n(/[​-‏‪-‮⁠⁦-⁩﻿]/g);
  const other = [...v].length - n(/[0-9]/g) - arabic - space - marks;
  if (arabic) parts.push(`Arabic-Indic digits: ${arabic}`);
  if (space) parts.push(`spaces/newlines: ${space}`);
  if (marks) parts.push(`invisible marks: ${marks}`);
  if (other) parts.push(`other characters: ${other}`);
  return parts.join(", ");
}

/** Removes what a paste can add (see INVISIBLE) from the bypass secret and the codes, and turns Arabic-Indic digits
 * in the codes into 0-9. Changes env in place (the test workers inherit it). Returns what was changed, without values. */
export function cleanStagingSecrets(env = process.env) {
  const notes = [];
  for (const k of [...OTP_VARS, "VERCEL_AUTOMATION_BYPASS_SECRET"]) {
    const raw = env[k];
    if (typeof raw !== "string" || !raw) continue;
    let v = raw.replace(INVISIBLE, "");
    if (k !== "VERCEL_AUTOMATION_BYPASS_SECRET") v = toAsciiDigits(v);
    if (v !== raw) { notes.push(`${k}: cleaned (was ${shapeOf(raw)})`); env[k] = v; }
  }
  return notes;
}

/** Throws if the run is not aimed at classi-staging or carries credentials that do not belong to a UI-only suite. */
export function checkStagingEnv(env = process.env) {
  for (const note of cleanStagingSecrets(env)) console.log(`[staging-guard] ${note}`);
  const problems = [];
  const base = env.BASE_URL ?? "";
  if (base.replace(/\/$/, "") !== TARGET.base) problems.push(`BASE_URL must be exactly ${TARGET.base}`);
  if (DRY_RUN && !env.CI) problems.push("the dry run is for CI only");
  if (!DRY_RUN && !env.VERCEL_AUTOMATION_BYPASS_SECRET) problems.push("VERCEL_AUTOMATION_BYPASS_SECRET is not set");
  for (const k of OTP_VARS) {
    const v = env[k] ?? "";
    if (!/^[0-9]{6}$/.test(v)) problems.push(`${k} must be the 6-digit test code (${v ? `seen: ${shapeOf(v)}` : "empty or not passed to this step"})`);
  }
  // No database or privileged credentials may be present in a UI-only run, whatever their name.
  for (const [k, v] of Object.entries(env)) {
    const val = String(v ?? "");
    if (/^postgres(ql)?:\/\//i.test(val)) problems.push(`${k} holds a database connection string`);
    if (/^sb_secret_/.test(val)) problems.push(`${k} holds a Supabase secret key`);
    if (/^eyJ/.test(val) && /service_role/.test(Buffer.from(val.split(".")[1] ?? "", "base64").toString("latin1"))) problems.push(`${k} holds a service_role key`);
    if (FORBIDDEN_HOSTS.some((re) => re.test(val.replace(/^https?:\/\//, "").split(/[/:?]/)[0]))) problems.push(`${k} points at production`);
  }
  if (problems.length) throw new Error("staging suite refused to start:\n- " + problems.join("\n- "));
}

/** The five accounts created by supabase/staging/staging_data.sql (Supabase test numbers with fixed codes). */
export const ACCOUNTS = {
  teacher: { phone: "0500000001", otpVar: "STAGING_OTP_TEACHER" },
  institute: { phone: "0500000002", otpVar: "STAGING_OTP_INSTITUTE" },
  parent: { phone: "0500000003", otpVar: "STAGING_OTP_PARENT" },
  student: { phone: "0500000004", otpVar: "STAGING_OTP_STUDENT" },
  admin: { phone: "0500000005", otpVar: "STAGING_OTP_ADMIN" },
};
