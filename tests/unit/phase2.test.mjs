// Phase 2 regression tests for pure logic (BUG-16, BUG-21, BUG-22, BUG-23, BUG-24).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const require = createRequire(import.meta.url);
const dir = process.env.CLASSI_LIB;
const { normalizeDigits, toE164 } = require(`${dir}/phone.js`);
const { cleanMobile } = require(`${dir}/contact.js`);
const { friendlyError } = require(`${dir}/errors.js`);
const { runPool } = require(`${dir}/pool.js`);

test("BUG-24: Arabic-Indic and Persian digits become 0-9", () => {
  assert.equal(normalizeDigits("٠٥٢١٢٣٤٥٦٧"), "0521234567");
  assert.equal(normalizeDigits("۰۵۲۱۲۳۴۵۶۷"), "0521234567");
  assert.equal(normalizeDigits("رمز ١٢٣٤٥٦"), "رمز 123456");
});
test("BUG-24: phone fields accept Arabic digits", () => {
  assert.equal(cleanMobile("٠٥٢-١٢٣ ٤٥٦٧"), "+972521234567");
  assert.equal(toE164("٠٥٢١٢٣٤٥٦٧"), "+972521234567");
  assert.equal(toE164("052-123-4567"), "+972521234567");
  assert.equal(toE164("+972 52 123 4567"), "+972521234567");
  assert.equal(toE164("12345"), null);
});
test("BUG-23: database errors become Arabic messages; Arabic messages pass through", () => {
  assert.match(friendlyError({ code: "42501", message: "new row violates row-level security policy for table \"teachers\"" }), /صلاحية/);
  assert.match(friendlyError({ code: "23505", message: "duplicate key value violates unique constraint" }), /موجود/);
  assert.match(friendlyError({ code: "23514", message: "new row for relation violates check constraint" }), /غير صالحة/);
  assert.match(friendlyError({ message: "TypeError: fetch failed" }), /الاتصال/);
  assert.equal(friendlyError({ code: "P0001", message: "الموعد لم يعد متاحاً، اختر موعداً آخر" }), "الموعد لم يعد متاحاً، اختر موعداً آخر");
  assert.match(friendlyError({ message: "Some English internal error" }), /تعذّر/);
  assert.equal(friendlyError(null), "");
});
test("BUG-22: runPool sends with bounded concurrency and keeps every result, even failures", async () => {
  let active = 0, peak = 0;
  const items = Array.from({ length: 23 }, (_, i) => i);
  const res = await runPool(items, 5, async (i) => {
    active++; peak = Math.max(peak, active);
    await new Promise((r) => setTimeout(r, 5));
    active--;
    if (i % 7 === 0) throw new Error("boom " + i);
    return i * 2;
  });
  assert.equal(peak, 5);
  assert.equal(res.length, 23);
  assert.deepEqual(res.filter((r) => !r.ok).map((r) => r.item), [0, 7, 14, 21]);
  assert.equal(res.find((r) => r.item === 3).value, 6);
});
test("BUG-21: fromLocal gives the same instant whatever the server time zone", () => {
  const here = fileURLToPath(import.meta.url);
  const script = `const {fromLocal}=require(${JSON.stringify(dir + "/format.js")});console.log(["2026-10-25 02:30","2027-03-26 03:30","2026-11-03 16:00","2026-07-07 16:00"].map(s=>fromLocal(...s.split(" ")).toISOString()).join(","))`;
  const run = (tz) => execFileSync(process.execPath, ["-e", script], { env: { ...process.env, TZ: tz } }).toString().trim();
  const utc = run("UTC");
  assert.equal(run("Asia/Jerusalem"), utc);
  assert.equal(run("America/New_York"), utc);
  assert.equal(utc, "2026-10-25T00:30:00.000Z,2027-03-26T00:30:00.000Z,2026-11-03T14:00:00.000Z,2026-07-07T13:00:00.000Z");
  void here;
});

test("BUG-03: chat merge keeps every message, newest last, no duplicates, temp replaced", () => {
  const { mergeMessages, lastStamp, firstStamp, PAGE_SIZE } = require(`${dir}/messages.js`);
  const m = (i, s = "a") => ({ id: `m${String(i).padStart(4, "0")}`, sender_id: s, body: `msg ${i}`, created_at: new Date(Date.UTC(2026, 10, 1, 10, 0, i)).toISOString(), read_at: null });
  // a thread of 350 messages: the page shows the newest PAGE_SIZE, then "load older" pages, then new ones arrive
  const all = Array.from({ length: 350 }, (_, i) => m(i));
  let thread = all.slice(-PAGE_SIZE);
  assert.equal(thread.at(-1).id, "m0349", "the newest message is on screen");
  while (thread.length < all.length) thread = mergeMessages(thread, all.filter((x) => x.created_at < firstStamp(thread)).slice(-PAGE_SIZE));
  assert.equal(thread.length, 350);
  const temp = { id: "tmp-1", sender_id: "me", body: "جديد", created_at: new Date().toISOString(), read_at: null };
  thread = mergeMessages(thread, [temp]);
  assert.equal(lastStamp(thread), all.at(-1).created_at, "temp messages are not used as the polling cursor");
  const real = { ...temp, id: "m9999", created_at: new Date(Date.UTC(2026, 10, 1, 11)).toISOString() };
  thread = mergeMessages(thread, [real, real, all[349]]);
  assert.equal(thread.length, 351);
  assert.equal(thread.filter((x) => x.id.startsWith("tmp-")).length, 0);
  assert.equal(thread.at(-1).id, "m9999", "the message sent after 300+ messages stays on screen");
  thread = mergeMessages(thread, [{ ...real, read_at: "2026-11-01T12:00:00Z" }]);
  assert.equal(thread.at(-1).read_at, "2026-11-01T12:00:00Z", "read receipts update in place");
});
