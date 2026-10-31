// Regression tests for the app-layer security fixes (audit SEC-09, SEC-26, SEC-29, I-2).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const dir = process.env.CLASSI_LIB;
const { safePath, withQuery, errorText } = require(`${dir}/safe.js`);
const { icsFile, foldIcsLine } = require(`${dir}/contact.js`);
const { escapeHtml } = require(`${dir}/escape.js`);

test("SEC-09 safePath refuses every off-site form", () => {
  for (const bad of ["//evil.com", "/\\evil.com", "/\t/evil.com", "https://evil.com", "evil.com", "", null, undefined, "/%0d%0aSet-Cookie", "/a\nb", "javascript:alert(1)"]) {
    const got = safePath(bad, "/home");
    assert.ok(got === "/home" || got === bad && !/^\/\/|^\/\\/.test(got), `${JSON.stringify(bad)} -> ${got}`);
    assert.notEqual(new URL(got, "https://classi.click").origin, "https://evil.com");
  }
  assert.equal(safePath("//evil.com", "/home"), "/home");
  assert.equal(safePath("/\\evil.com", "/home"), "/home");
  assert.equal(safePath("/\t/evil.com", "/home"), "/home");
});
test("SEC-09 safePath keeps normal paths with query and hash", () => {
  assert.equal(safePath("/teach/calendar?day=2026-11-03#hours"), "/teach/calendar?day=2026-11-03#hours");
  assert.equal(safePath("/manage/course/abc?x=1&y=2"), "/manage/course/abc?x=1&y=2");
});
test("BUG-20 withQuery picks ? or &", () => {
  assert.equal(withQuery("/teach", "ok=1"), "/teach?ok=1");
  assert.equal(withQuery("/teach?day=1", "ok=1"), "/teach?day=1&ok=1");
});
test("SEC-26 errorText blocks phishing lures but keeps real messages", () => {
  assert.equal(errorText("الموعد لم يعد متاحاً، اختر موعداً آخر"), "الموعد لم يعد متاحاً، اختر موعداً آخر");
  assert.equal(errorText("الدورة ممتلئة (12 من 12 مقاعد). زِد عدد المقاعد أولاً."), "الدورة ممتلئة (12 من 12 مقاعد). زِد عدد المقاعد أولاً.");
  for (const lure of ["حسابك موقوف، اتصل على 050-123-4567", "ادخل إلى https://evil.example لتأكيد حسابك", "راسلنا على help@evil.co",
                      "حدّث بياناتك في www.evil.com", "رمزك ٠٥٠١٢٣٤٥٦٧", "x".repeat(300)]) {
    assert.notEqual(errorText(lure), lure, lure);
  }
  assert.equal(errorText(""), null);
  assert.equal(errorText(undefined), null);
});
test("SEC-29 ICS: a carriage return in a title cannot inject a property", () => {
  const ics = icsFile([{ uid: "1", title: "حصة\rURL:https://evil.example", start: "2026-11-03T14:00:00Z", minutes: 60, details: "x" }]);
  const lines = ics.split("\r\n").filter((l) => !l.startsWith(" "));
  assert.equal(lines.filter((l) => l.startsWith("URL:")).length, 0);
  assert.equal(lines.filter((l) => l.startsWith("SUMMARY:")).length, 1);
});
test("SEC-29 ICS: long Arabic lines are folded at 75 octets without splitting characters", () => {
  const line = "SUMMARY:" + "رياضيات بجروت خمس وحدات مع المعلم سامر مصاروة في باقة الغربية";
  const folded = foldIcsLine(line);
  for (const part of folded.split("\r\n")) assert.ok(new TextEncoder().encode(part).length <= 75, part);
  assert.equal(folded.split("\r\n").map((p, i) => (i ? p.slice(1) : p)).join(""), line);
});
test("I-2 escapeHtml", () => assert.equal(escapeHtml(`<b onclick="x">&'`), "&lt;b onclick=&quot;x&quot;&gt;&amp;&#39;"));
