// Phase 5: the build refuses wrong Supabase settings (sensitive variables cannot be read back from Vercel).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { deployProblems, deploySummary } = require(`${process.env.CLASSI_LIB}/deploy-guard.js`);
const S = "https://nfipmylyahhogykikuqo.supabase.co", P = "https://rfxhqcagdsuhkjzwbawx.supabase.co";
const jwt = { stagingAnon: "eyJhbGciOiJIUzI1NiJ9.eyJyZWYiOiAibmZpcG15bHlhaGhvZ3lraWt1cW8iLCAicm9sZSI6ICJhbm9uIn0.sig", prodAnon: "eyJhbGciOiJIUzI1NiJ9.eyJyZWYiOiAicmZ4aHFjYWdkc3Voa2p6d2Jhd3giLCAicm9sZSI6ICJhbm9uIn0.sig",
              stagingService: "eyJhbGciOiJIUzI1NiJ9.eyJyZWYiOiAibmZpcG15bHlhaGhvZ3lraWt1cW8iLCAicm9sZSI6ICJzZXJ2aWNlX3JvbGUifQ.sig" };
const stg = (url, key) => deployProblems({ NEXT_PUBLIC_DEPLOY_ENV: "staging", NEXT_PUBLIC_SUPABASE_URL: url, NEXT_PUBLIC_SUPABASE_ANON_KEY: key });

test("staging with the staging URL and the staging anon or publishable key passes", () => {
  assert.deepEqual(stg(S, jwt.stagingAnon), []);
  assert.deepEqual(stg(S, "sb_publishable_abc"), []);
});
test("staging pointing at production, another project, or with a production key fails", () => {
  assert.ok(stg(P, jwt.stagingAnon).length);
  assert.ok(stg("https://other.supabase.co", jwt.stagingAnon).length);
  assert.ok(stg(S, jwt.prodAnon).length);
  assert.ok(stg(S, "").length);
});
test("a secret or service_role key fails in any build", () => {
  assert.ok(stg(S, "sb_secret_abc").length);
  assert.ok(stg(S, jwt.stagingService).length);
  assert.ok(deployProblems({ VERCEL_ENV: "production", NEXT_PUBLIC_SUPABASE_URL: P, NEXT_PUBLIC_SUPABASE_ANON_KEY: "sb_secret_x" }).length);
});
test("production pointing at the staging database fails; production on production passes", () => {
  assert.ok(deployProblems({ VERCEL_ENV: "production", NEXT_PUBLIC_SUPABASE_URL: S, NEXT_PUBLIC_SUPABASE_ANON_KEY: jwt.stagingAnon }).length);
  assert.deepEqual(deployProblems({ VERCEL_ENV: "production", NEXT_PUBLIC_SUPABASE_URL: P, NEXT_PUBLIC_SUPABASE_ANON_KEY: jwt.prodAnon }), []);
});
test("the summary never contains a value", () => {
  const line = deploySummary({ NEXT_PUBLIC_DEPLOY_ENV: "staging", NEXT_PUBLIC_SUPABASE_URL: S, NEXT_PUBLIC_SUPABASE_ANON_KEY: jwt.stagingAnon });
  assert.equal(line, "[deploy-check] env=staging supabase=classi-staging key=jwt role=anon key-project=classi-staging worker-key=missing");
  assert.ok(!line.includes("eyJ") && !line.includes("https://"));
});
