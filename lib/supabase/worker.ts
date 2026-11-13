import { createClient, type SupabaseClient } from "@supabase/supabase-js";

// D-08 / TM-13: the dispatch routes (/api/push/dispatch, /api/sms/otp) call the worker_* database functions, which only
// the service role may execute. The key lives in Vercel as SUPABASE_SERVICE_ROLE_KEY (Production / the staging project
// only, never NEXT_PUBLIC_, never sent to a browser). ONLY these two routes may import this module: tests/check-worker-key.mjs
// fails the build if any other file imports it or if a client component could reach it.
// Without the key the routes fall back to the old anon path, which works only until step B (20261114010000) removes it;
// /api/health reports the missing key as a failure.

export function workerKeyConfigured(env: Record<string, string | undefined> = process.env): boolean {
  return !!(env.SUPABASE_SERVICE_ROLE_KEY ?? "").trim();
}

export function workerClient(): SupabaseClient | null {
  const key = (process.env.SUPABASE_SERVICE_ROLE_KEY ?? "").trim();
  const url = (process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").trim();
  if (!key || !url) return null;
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });
}
