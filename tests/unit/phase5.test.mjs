// Phase 5: a staging build can never send a real SMS (019 test endpoint), even for sign-in codes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const dir = process.env.CLASSI_LIB;

async function urlUsed(env, forceReal) {
  const saved = { ...process.env };
  Object.assign(process.env, { SMS_019_TOKEN: "t", SMS_019_USER: "u" }, env);
  let url = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (u) => { url = String(u); return new Response(JSON.stringify({ status: 0 }), { status: 200 }); };
  try {
    delete require.cache[require.resolve(`${dir}/sms.js`)];
    const { sendSms } = require(`${dir}/sms.js`);
    await sendSms("0500000000", "x", forceReal ? false : undefined);
  } finally { globalThis.fetch = realFetch; process.env = saved; }
  return url;
}

const PROD = { VERCEL_ENV: "production", VERCEL_PROJECT_PRODUCTION_URL: "classi.click", NEXT_PUBLIC_DEPLOY_ENV: "", SMS_019_TEST: "" };

test("staging: sign-in codes (sent with test=false) still go to the test endpoint", async () => {
  assert.match(await urlUsed({ ...PROD, NEXT_PUBLIC_DEPLOY_ENV: "staging", VERCEL_PROJECT_PRODUCTION_URL: "classi-staging.vercel.app" }, true), /\/api\/test$/);
});
test("staging: notifications go to the test endpoint", async () => {
  assert.match(await urlUsed({ ...PROD, NEXT_PUBLIC_DEPLOY_ENV: "staging" }, false), /\/api\/test$/);
});
test("production: sign-in codes and notifications go to the real endpoint", async () => {
  assert.match(await urlUsed(PROD, true), /\/api$/);
  assert.match(await urlUsed({ ...PROD, VERCEL_PROJECT_PRODUCTION_URL: "www.classi.click" }, false), /\/api$/);
});
test("staging project without NEXT_PUBLIC_DEPLOY_ENV still never sends (domain is not classi.click)", async () => {
  assert.match(await urlUsed({ ...PROD, VERCEL_PROJECT_PRODUCTION_URL: "classi-staging.vercel.app" }, true), /\/api\/test$/);
});
test("previews, local runs and look-alike domains never send", async () => {
  for (const env of [{ ...PROD, VERCEL_ENV: "preview" }, { ...PROD, VERCEL_ENV: "" },
                     { ...PROD, VERCEL_PROJECT_PRODUCTION_URL: "classi.click.evil.com" }, { ...PROD, VERCEL_PROJECT_PRODUCTION_URL: "notclassi.click" }])
    assert.match(await urlUsed(env, true), /\/api\/test$/);
});
test("a staging variable copied into production fails safe (test endpoint)", async () => {
  assert.match(await urlUsed({ ...PROD, NEXT_PUBLIC_DEPLOY_ENV: "staging" }, true), /\/api\/test$/);
  assert.match(await urlUsed({ ...PROD, SMS_019_TEST: "1" }, true), /\/api\/test$/);
});
