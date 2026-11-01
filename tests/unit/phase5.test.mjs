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

test("staging: sign-in codes (sent with test=false) still go to the test endpoint", async () => {
  assert.match(await urlUsed({ NEXT_PUBLIC_DEPLOY_ENV: "staging" }, true), /\/api\/test$/);
});
test("staging: notifications go to the test endpoint", async () => {
  assert.match(await urlUsed({ NEXT_PUBLIC_DEPLOY_ENV: "staging" }, false), /\/api\/test$/);
});
test("production: sign-in codes go to the real endpoint", async () => {
  assert.match(await urlUsed({ NEXT_PUBLIC_DEPLOY_ENV: "" , SMS_019_TEST: "" }, true), /\/api$/);
});
