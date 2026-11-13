// D-08 / TM-13 regression guard. The service-role key (SUPABASE_SERVICE_ROLE_KEY) bypasses every row-level rule, so:
//  1. only the server files listed in ALLOWED may import lib/supabase/worker (the dispatch routes and the health checks);
//  2. none of them may be a client component, and no client component may import them;
//  3. the variable is read only in lib/supabase/worker.ts and lib/deploy-guard.ts (never NEXT_PUBLIC_);
//  4. the old secret-gated anon functions are not called anywhere except the temporary fallback in the two routes;
//  5. a Web Push never carries the notification body (TM-12): the payload comes from lib/push-text.ts;
//  6. the probe route (app/api/push/probe) only wakes: it never claims, delivers, logs or drops anything.
// Usage: node tests/check-worker-key.mjs
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const files = [];
const walk = (d) => { for (const f of readdirSync(d)) { const p = join(d, f); if (statSync(p).isDirectory()) { if (!["node_modules", ".next"].includes(f)) walk(p); } else if (/\.(ts|tsx|js|mjs)$/.test(f)) files.push(p); } };
["app", "lib", "components", "public"].forEach((d) => walk(join(root, d)));
const rel = (p) => p.slice(root.length);
const src = Object.fromEntries(files.map((f) => [rel(f), readFileSync(f, "utf8")]));

const ALLOWED = ["app/api/push/dispatch/route.ts", "app/api/sms/otp/route.ts", "app/api/push/probe/route.ts", "lib/health.ts"];
const KEY_READERS = ["lib/supabase/worker.ts", "lib/deploy-guard.ts"];
const LEGACY = ["claim_push", "claim_otp", "log_sms", "drop_push_subscriptions"];
let bad = 0;
const fail = (m) => { console.log(`FAIL: ${m}`); bad++; };
const isClient = (s) => /^\s*["']use client["']/m.test(s.split("\n").slice(0, 5).join("\n"));

for (const [f, s] of Object.entries(src)) {
  if (f === "lib/supabase/worker.ts") continue;
  const importsWorker = /from\s+["'](@\/lib\/supabase\/worker|\.\.?\/(?:[\w-]+\/)*supabase\/worker|\.\/worker)["']/.test(s);
  if (importsWorker && !ALLOWED.includes(f)) fail(`${f} imports lib/supabase/worker (only ${ALLOWED.join(", ")} may)`);
  if (importsWorker && isClient(s)) fail(`${f} is a client component and imports the server-only key module`);
  if (isClient(s) && /from\s+["']@\/lib\/health["']/.test(s)) fail(`${f} is a client component and imports lib/health`);
  if (/(env\.SUPABASE_SERVICE_ROLE_KEY|\[\s*["']SUPABASE_SERVICE_ROLE_KEY["']\s*\])/.test(s) && !KEY_READERS.includes(f)) fail(`${f} reads SUPABASE_SERVICE_ROLE_KEY (only ${KEY_READERS.join(", ")} may)`);
  if (/NEXT_PUBLIC_[A-Z_]*SERVICE|NEXT_PUBLIC_[A-Z_]*SECRET/.test(s)) fail(`${f} mentions a NEXT_PUBLIC_ service/secret variable`);
  for (const fn of LEGACY) {
    if (new RegExp(`rpc\\(\\s*["']${fn}["']`).test(s) && !["app/api/push/dispatch/route.ts", "app/api/sms/otp/route.ts"].includes(f))
      fail(`${f} calls the old anon function ${fn}`);
  }
}
const dispatch = src["app/api/push/dispatch/route.ts"] ?? "";
if (/sendNotification\([\s\S]{0,200}it\.body/.test(dispatch)) fail("app/api/push/dispatch/route.ts puts the notification body into a Web Push (TM-12)");
if (!/pushPayload\(it\)/.test(dispatch)) fail("app/api/push/dispatch/route.ts does not build the push with pushPayload (lib/push-text.ts)");
const probe = src["app/api/push/probe/route.ts"] ?? "";
if (!probe) fail("app/api/push/probe/route.ts is missing");
for (const bad of ["worker_claim", "worker_push_keys", "worker_log_sms", "worker_drop", "claim_push", "claim_otp", "sendNotification", "sendSms", "resend", "web-push", "lib/sms", "publicClient"])
  if (probe.toLowerCase().includes(bad.toLowerCase())) fail(`app/api/push/probe/route.ts must only wake (found "${bad}")`);
if (!/rpc\(\s*["']worker_wake_ok["']/.test(probe)) fail("app/api/push/probe/route.ts does not call worker_wake_ok");
console.log(bad ? `${bad} problem(s)` : `worker key and push text: ok (${files.length} files)`);
process.exit(bad ? 1 : 0);
