// Phase 5: the hosted staging suite refuses to start with a wrong target or any database / privileged credential.
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkStagingEnv, cleanStagingSecrets, shapeOf } from "../staging/guard.mjs";

const ok = { BASE_URL: "https://classi-staging.vercel.app", VERCEL_AUTOMATION_BYPASS_SECRET: "x".repeat(32),
  STAGING_OTP_TEACHER: "111111", STAGING_OTP_INSTITUTE: "222222", STAGING_OTP_PARENT: "333333", STAGING_OTP_STUDENT: "444444", STAGING_OTP_ADMIN: "555555" };
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
