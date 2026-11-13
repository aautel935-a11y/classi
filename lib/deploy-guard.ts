// Build-time check of the Supabase settings (phase 5). Vercel keeps "sensitive" variables unreadable, even to the
// owner, so the build itself verifies them and refuses to produce a site with the wrong database or a secret key.
// Only yes/no facts are reported; no value is ever printed.
export const STAGING_REF = "nfipmylyahhogykikuqo";
export const PRODUCTION_REF = "rfxhqcagdsuhkjzwbawx";

type Env = Record<string, string | undefined>;

function jwtClaims(key: string): { ref?: string; role?: string } | null {
  const part = key.split(".")[1];
  if (!part) return null;
  try {
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    return JSON.parse(atob(b64));
  } catch { return null; }
}

/** Problems with this build's Supabase settings (empty = fine). */
export function deployProblems(env: Env): string[] {
  const url = (env.NEXT_PUBLIC_SUPABASE_URL ?? "").trim();
  const key = (env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "").trim();
  const staging = env.NEXT_PUBLIC_DEPLOY_ENV === "staging";
  const problems: string[] = [];
  // A secret key must never reach the browser, in any build.
  if (/^sb_secret_/.test(key)) problems.push("NEXT_PUBLIC_SUPABASE_ANON_KEY is a secret key (sb_secret_…), not the publishable/anon key");
  const claims = key.startsWith("eyJ") ? jwtClaims(key) : null;
  if (claims?.role && claims.role !== "anon") problems.push(`NEXT_PUBLIC_SUPABASE_ANON_KEY is a "${claims.role}" key, not anon`);
  if (staging) {
    if (url !== `https://${STAGING_REF}.supabase.co`) problems.push("staging build: NEXT_PUBLIC_SUPABASE_URL is not the classi-staging project");
    if (!key) problems.push("staging build: NEXT_PUBLIC_SUPABASE_ANON_KEY is empty");
    if (claims && claims.ref !== STAGING_REF) problems.push("staging build: the anon key belongs to another project");
    if (key.includes(PRODUCTION_REF)) problems.push("staging build: the key mentions the production project");
  } else if (env.VERCEL_ENV === "production") {
    if (url.includes(STAGING_REF) || claims?.ref === STAGING_REF) problems.push("production build points at the classi-staging database");
  }
  problems.push(...workerKeyProblems(env));
  return problems;
}

/**
 * D-08 / TM-13: the server-only key of the dispatch routes. It must never be a NEXT_PUBLIC_ variable (those are built
 * into the browser code), and when it is a JWT it must be the service_role key of the same project as the site.
 */
export function workerKeyProblems(env: Env): string[] {
  const problems: string[] = [];
  for (const [name, value] of Object.entries(env)) {
    if (!name.startsWith("NEXT_PUBLIC_") || !value) continue;
    const v = value.trim();
    const c = v.startsWith("eyJ") ? jwtClaims(v) : null;
    if (/^sb_secret_/.test(v) || c?.role === "service_role") problems.push(`${name} holds a server-only (service role / secret) key`);
  }
  const key = (env.SUPABASE_SERVICE_ROLE_KEY ?? "").trim();
  if (!key) return problems;
  if (/^sb_publishable_/.test(key)) problems.push("SUPABASE_SERVICE_ROLE_KEY is a publishable key, not the secret / service role key");
  const claims = key.startsWith("eyJ") ? jwtClaims(key) : null;
  if (claims) {
    if (claims.role !== "service_role") problems.push(`SUPABASE_SERVICE_ROLE_KEY is a "${claims.role ?? "?"}" key, not service_role`);
    const url = (env.NEXT_PUBLIC_SUPABASE_URL ?? "").trim();
    const m = /^https:\/\/([a-z0-9]{20})\.supabase\.co\/?$/.exec(url);
    if (m && claims.ref && claims.ref !== m[1]) problems.push("SUPABASE_SERVICE_ROLE_KEY belongs to another Supabase project than NEXT_PUBLIC_SUPABASE_URL");
  } else if (!/^sb_secret_/.test(key)) {
    problems.push("SUPABASE_SERVICE_ROLE_KEY is not a Supabase secret key (sb_secret_…) or a service_role JWT");
  }
  return problems;
}

/** One line for the build log: yes/no facts only. */
export function deploySummary(env: Env): string {
  const key = (env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "").trim();
  const claims = key.startsWith("eyJ") ? jwtClaims(key) : null;
  const kind = key.startsWith("sb_publishable_") ? "publishable" : claims ? `jwt role=${claims.role ?? "?"}` : key ? "other" : "missing";
  const url = env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const target = url.includes(STAGING_REF) ? "classi-staging" : url.includes(PRODUCTION_REF) ? "production" : url ? "other" : "missing";
  const keyProject = claims?.ref ? (claims.ref === STAGING_REF ? "classi-staging" : claims.ref === PRODUCTION_REF ? "production" : "other") : "n/a";
  const worker = (env.SUPABASE_SERVICE_ROLE_KEY ?? "").trim() ? "set" : "missing";
  return `[deploy-check] env=${env.NEXT_PUBLIC_DEPLOY_ENV === "staging" ? "staging" : "production/other"} supabase=${target} key=${kind} key-project=${keyProject} worker-key=${worker}`;
}
