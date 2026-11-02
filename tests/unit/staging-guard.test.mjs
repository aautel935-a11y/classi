// Phase 5: the hosted staging suite refuses to start with a wrong target or any database / privileged credential.
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkStagingEnv, cleanStagingSecrets, shapeOf } from "../staging/guard.mjs";

const ok = { BASE_URL: "https://classi-staging.vercel.app", VERCEL_AUTOMATION_BYPASS_SECRET: "x".repeat(32),
  STAGING_OTP_TEACHER: "111111", STAGING_OTP_INSTITUTE: "222222", STAGING_OTP_PARENT: "333333", STAGING_OTP_STUDENT: "444444", STAGING_OTP_ADMIN: "555555" };
const OTPS = ["TEACHER", "INSTITUTE", "PARENT", "STUDENT", "ADMIN"].map((r) => `STAGING_OTP_${r}`);
const refuses = (env, re) => assert.throws(() => checkStagingEnv(env), re);
const jwt = (claims) => "eyJhbGciOiJIUzI1NiJ9." + Buffer.from(JSON.stringify(claims)).toString("base64url") + ".sig";

test("the correct staging settings pass", () => { assert.doesNotThrow(() => checkStagingEnv(ok)); });
test("a production or other target is refused", () => {
  refuses({ ...ok, BASE_URL: "https://classi.click" }, /BASE_URL/);
  refuses({ ...ok, BASE_URL: "https://classi-staging.vercel.app.evil.com" }, /BASE_URL/);
  refuses({ ...ok, BASE_URL: "https://classi-staging-abc.vercel.app" }, /BASE_URL/);
});
test("any database connection string in the environment is refused", () => {
  refuses({ ...ok, E2E_DB_URL: "postgresql://e2e_staging.nfipmylyahhogykikuqo:x@host:5432/postgres" }, /database connection/);
  refuses({ ...ok, SOMETHING: "postgres://u:p@h/db" }, /database connection/);
});
test("secret and service_role keys are refused", () => {
  refuses({ ...ok, KEY: "sb_secret_abc" }, /secret key/);
  refuses({ ...ok, KEY: jwt({ role: "service_role", ref: "nfipmylyahhogykikuqo" }) }, /service_role/);
});
test("a value pointing at production is refused", () => {
  refuses({ ...ok, X: "https://rfxhqcagdsuhkjzwbawx.supabase.co" }, /production/);
  refuses({ ...ok, X: "https://www.classi.click/api" }, /production/);
});
test("missing or malformed test codes and bypass secret are refused", () => {
  refuses({ ...ok, STAGING_OTP_ADMIN: "" }, /STAGING_OTP_ADMIN/);
  refuses({ ...ok, STAGING_OTP_PARENT: "12345" }, /STAGING_OTP_PARENT/);
  refuses({ ...ok, VERCEL_AUTOMATION_BYPASS_SECRET: "" }, /BYPASS/);
});
test("pasted codes and bypass secret are cleaned (newlines, spaces, direction marks, Arabic-Indic digits)", () => {
  const env = { ...ok, STAGING_OTP_TEACHER: "111111\n", STAGING_OTP_INSTITUTE: " 222222 ", STAGING_OTP_PARENT: "‏333333",
    STAGING_OTP_STUDENT: "٤٤٤٤٤٤", STAGING_OTP_ADMIN: "۵۵۵۵۵۵\r\n", VERCEL_AUTOMATION_BYPASS_SECRET: "x".repeat(32) + "\n" };
  const notes = cleanStagingSecrets(env);
  assert.equal(notes.length, 6);
  assert.deepEqual([env.STAGING_OTP_TEACHER, env.STAGING_OTP_INSTITUTE, env.STAGING_OTP_PARENT, env.STAGING_OTP_STUDENT, env.STAGING_OTP_ADMIN],
    ["111111", "222222", "333333", "444444", "555555"]);
  assert.equal(env.VERCEL_AUTOMATION_BYPASS_SECRET, "x".repeat(32));
  assert.doesNotThrow(() => checkStagingEnv({ ...ok, STAGING_OTP_ADMIN: "555555\n" }));
});
test("cleaning never turns a wrong code into a valid one, and messages never contain the value", () => {
  refuses({ ...ok, STAGING_OTP_ADMIN: "1234 5x" }, /STAGING_OTP_ADMIN must be the 6-digit test code \(seen: length 6, digits 0-9: 5, other characters: 1\)/);
  refuses({ ...ok, STAGING_OTP_PARENT: "1234567" }, /length 7/);
  try { checkStagingEnv({ ...ok, STAGING_OTP_ADMIN: "98765x" }); } catch (e) { assert.ok(!e.message.includes("98765")); }
  const notes = cleanStagingSecrets({ STAGING_OTP_TEACHER: "424242\n" });
  assert.ok(!notes.join(" ").includes("424242"));
  assert.equal(shapeOf("12‏٣ "), "length 5, digits 0-9: 2, Arabic-Indic digits: 1, spaces/newlines: 1, invisible marks: 1");
});
test("no message ever contains any 3-character piece of a code or of the bypass secret", () => {
  const rnd = (n, set) => Array.from({ length: n }, () => set[Math.floor(Math.random() * set.length)]).join("");
  for (let i = 0; i < 200; i++) {
    const secret = rnd(32, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789");
    const codes = OTPS.map(() => rnd(6, "0123456789"));
    const pasted = (s) => ["", "\n", " ", "‏", "\r\n"][i % 5] + s + ["\n", "", " \n", "‎", ""][i % 5];
    // wrong lengths too, so the refusal messages are produced
    const env = { ...ok, VERCEL_AUTOMATION_BYPASS_SECRET: pasted(secret) };
    OTPS.forEach((k, j) => { env[k] = pasted(i % 2 ? codes[j] : codes[j] + "7"); });
    const out = [...cleanStagingSecrets({ ...env })];
    try { checkStagingEnv(env); } catch (e) { out.push(e.message); }
    const text = out.join("\n");
    // the secret: no 6-character piece (shorter letter runs occur by chance in English words such as "marks")
    for (let p = 0; p + 6 <= secret.length; p++) if (text.includes(secret.slice(p, p + 6))) assert.fail("message holds a piece of the secret");
    // the codes: no 3 digits in a row, once the allowed counts ("length 7", "digits 0-9: 6", ...) are removed
    const noCounts = text.replace(/(length|digits 0-9:|spaces\/newlines:|invisible marks:|other characters:|Arabic-Indic digits:) \d+/g, "");
    for (const v of [...codes, ...codes.map((c) => c + "7")])
      for (let p = 0; p + 3 <= v.length; p++) if (noCounts.includes(v.slice(p, p + 3))) assert.fail("message holds digits of a code");
  }
});
test("the bypass secret's description says nothing about its own characters", () => {
  assert.equal(shapeOf("abc123\n", { secret: true }), "length 7, spaces/newlines: 1, invisible marks: 0");
  const [note] = cleanStagingSecrets({ VERCEL_AUTOMATION_BYPASS_SECRET: "a1b2c3d4e5f6\n" });
  assert.ok(!/digits|other/.test(note), note);
});
