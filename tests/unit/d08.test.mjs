// D-08: TM-12 (neutral push text), TM-14 (the code is read from the SMS text), TM-13 (the server-only key is checked at build).
// Fake keys only: these JWTs have a made-up signature and carry no secret.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { pushText, pushPayload } = require(`${process.env.CLASSI_LIB}/push-text.js`);
const { codeFromBody } = require(`${process.env.CLASSI_LIB}/otp-code.js`);
const { deployProblems, workerKeyProblems, deploySummary } = require(`${process.env.CLASSI_LIB}/deploy-guard.js`);

const S = "https://nfipmylyahhogykikuqo.supabase.co", P = "https://rfxhqcagdsuhkjzwbawx.supabase.co";
const key = {
  stagingAnon: "eyJhbGciOiJIUzI1NiJ9.eyJyZWYiOiAibmZpcG15bHlhaGhvZ3lraWt1cW8iLCAicm9sZSI6ICJhbm9uIn0.sig",
  stagingService: "eyJhbGciOiJIUzI1NiJ9.eyJyZWYiOiAibmZpcG15bHlhaGhvZ3lraWt1cW8iLCAicm9sZSI6ICJzZXJ2aWNlX3JvbGUifQ.sig",
  prodService: "eyJhbGciOiJIUzI1NiJ9.eyJyZWYiOiAicmZ4aHFjYWdkc3Voa2p6d2Jhd3giLCAicm9sZSI6ICJzZXJ2aWNlX3JvbGUifQ.sig",
};

// ---------- TM-12 ----------
const KINDS = ["reminder", "reminder_today", "reminder_soon", "booking_answer", "booking_request", "booking_new", "booking_cancelled",
  "schedule_changed", "waitlist_open", "waitlist_answer", "waitlist_join", "verified", "message", "lesson_report", "report_due",
  "payment_reported", "payment_answer", "review_needed", "review_answer", "subscription", "review_new", "review_prompt", "admin_note",
  "review", "staff_invite", "staff_answer", "staff_removed", "booking_withdrawn", "link_request", "link_answer", "something_new", ""];

test("TM-12: every pushed kind gets a neutral line that names no one and no time", () => {
  for (const k of KINDS) {
    const t = pushText(k);
    assert.ok(t.length > 5 && t.length < 60, k);
    assert.doesNotMatch(t, /\d/, `${k}: no digits (times, dates, amounts)`);
    assert.match(t, /Classi/, k);
  }
  assert.equal(pushText("message"), "وصلتك رسالة جديدة في Classi");
  assert.equal(pushText("reminder_soon"), "تذكير بموعد قادم في Classi");
});

test("TM-12: the push payload never carries the notification body", () => {
  const body = "رسالة من أم يوسف: موعد الغد 17:00 مع سامر مصاروة، 120 ₪";
  const p = JSON.parse(pushPayload({ id: "n1", kind: "message", body }));
  assert.deepEqual(Object.keys(p).sort(), ["body", "title", "url"].sort());
  assert.equal(p.url, "/n/n1");
  const s = pushPayload({ id: "n1", kind: "message", body });
  for (const word of ["أم يوسف", "17:00", "سامر", "120"]) assert.ok(!s.includes(word), word);
  assert.equal(JSON.parse(pushPayload({ id: "r2", kind: "reminder", body })).tag, "r-r2");
});

// ---------- TM-14 ----------
test("TM-14: the code is read from the SMS text (no separate column)", () => {
  assert.equal(codeFromBody("482913 هو رمز الدخول إلى Classi. صالح 5 دقائق. لا تشاركه مع أحد."), "482913");
  assert.equal(codeFromBody("رمزك 004211 صالح 5 دقائق"), "004211");
  assert.equal(codeFromBody("صالح 5 دقائق"), null);
  assert.equal(codeFromBody("1234567 too long"), null);
  assert.equal(codeFromBody(""), null);
});

// ---------- TM-13 ----------
test("TM-13: a service key in a NEXT_PUBLIC_ variable fails the build", () => {
  assert.ok(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_ANON_KEY: key.stagingService }).length);
  assert.ok(workerKeyProblems({ NEXT_PUBLIC_SERVICE_KEY: "sb_secret_abc" }).length);
  assert.deepEqual(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_ANON_KEY: key.stagingAnon, NEXT_PUBLIC_SUPABASE_URL: S }), []);
});

test("TM-13: SUPABASE_SERVICE_ROLE_KEY must be the secret key of the same project", () => {
  assert.deepEqual(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_URL: S, SUPABASE_SERVICE_ROLE_KEY: key.stagingService }), []);
  assert.deepEqual(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_URL: P, SUPABASE_SERVICE_ROLE_KEY: key.prodService }), []);
  assert.deepEqual(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_URL: S, SUPABASE_SERVICE_ROLE_KEY: "sb_secret_abc" }), []);
  assert.ok(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_URL: S, SUPABASE_SERVICE_ROLE_KEY: key.prodService }).length, "other project");
  assert.ok(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_URL: S, SUPABASE_SERVICE_ROLE_KEY: key.stagingAnon }).length, "anon key");
  assert.ok(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_URL: S, SUPABASE_SERVICE_ROLE_KEY: "sb_publishable_abc" }).length, "publishable");
  assert.ok(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_URL: S, SUPABASE_SERVICE_ROLE_KEY: "not-a-key" }).length, "garbage");
  assert.deepEqual(workerKeyProblems({ NEXT_PUBLIC_SUPABASE_URL: S }), [], "missing key: allowed (fallback), reported by /api/health");
});

test("TM-13: the build summary says whether the key is set, never its value", () => {
  const env = { NEXT_PUBLIC_DEPLOY_ENV: "staging", NEXT_PUBLIC_SUPABASE_URL: S, NEXT_PUBLIC_SUPABASE_ANON_KEY: key.stagingAnon, SUPABASE_SERVICE_ROLE_KEY: key.stagingService };
  const line = deploySummary(env);
  assert.match(line, /worker-key=set/);
  assert.ok(!line.includes(key.stagingService) && !line.includes("eyJ"));
  assert.deepEqual(deployProblems(env), []);
  assert.match(deploySummary({ ...env, SUPABASE_SERVICE_ROLE_KEY: "" }), /worker-key=missing/);
});
