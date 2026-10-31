// Unit tests for Classi's pure logic (lib/format.ts, lib/dates.ts, lib/contact.ts).
// Run: bash tests/run-unit.sh  (compiles lib/*.ts with tsc into a temp dir, then `node --test`)
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const dir = process.env.CLASSI_LIB;
const { fromLocal, time, isoDay, weekday } = require(`${dir}/format.js`);
const { privateSlots, datesOn, nextDays } = require(`${dir}/dates.js`);
const { waLink, cleanMobile, googleCalLink, icsFile } = require(`${dir}/contact.js`);

const iso = (d) => d.toISOString();
const show = (s) => s.map((x) => x.time + (x.busy ? "x" : "")).join(" ");
const day = "2026-11-03"; // Tuesday, winter time (UTC+2)

test("fromLocal: Israel winter time is UTC+2", () => assert.equal(iso(fromLocal("2026-11-03", "16:00")), "2026-11-03T14:00:00.000Z"));
test("fromLocal: Israel summer time is UTC+3", () => assert.equal(iso(fromLocal("2026-07-07", "16:00")), "2026-07-07T13:00:00.000Z"));
test("fromLocal: day after DST ends (2026-10-25)", () => assert.equal(iso(fromLocal("2026-10-26", "09:00")), "2026-10-26T07:00:00.000Z"));
test("fromLocal: day after DST starts (2027-03-26)", () => assert.equal(iso(fromLocal("2027-03-27", "09:00")), "2027-03-27T06:00:00.000Z"));
test("time/isoDay/weekday round-trip in Israel time", () => {
  const d = fromLocal(day, "23:30");
  assert.equal(time(d), "23:30");
  assert.equal(isoDay(d), day);
  assert.equal(weekday(d), 2);
});

test("datesOn: next N meetings on chosen weekdays", () => {
  assert.deepEqual(datesOn("2026-11-01", [0, 2], 4), ["2026-11-01", "2026-11-03", "2026-11-08", "2026-11-10"]);
});
test("nextDays starts tomorrow (documented behaviour)", () => {
  assert.deepEqual(nextDays(3, new Date("2026-11-01T10:00:00Z")), ["2026-11-02", "2026-11-03", "2026-11-04"]);
});
test("nextDays skips Saturday", () => {
  assert.ok(!nextDays(14, new Date("2026-11-01T10:00:00Z")).some((d) => new Date(d + "T12:00:00Z").getUTCDay() === 6));
});
// KNOWN BUG (CLASSI_BUG_REPORT BUG-01): /teach lets a teacher set Saturday hours, but the booking calendar never shows Saturday.
test("BUG-01: Saturday availability is never offered to students", { todo: "remove the Saturday skip or hide Saturday in /teach" }, () => {
  const sat = { weekday: 6, start_time: "10:00", end_time: "12:00" };
  const days = nextDays(7, new Date("2026-11-01T10:00:00Z"));
  assert.ok(privateSlots([sat], [], 60, days).length > 0);
});

const av = [{ weekday: 2, start_time: "16:00", end_time: "20:00" }];
const busyAt = (hhmm, m) => ({ starts_at: iso(fromLocal(day, hhmm)), minutes: m });
test("slots: 90-minute lessons do not overlap", () => assert.equal(show(privateSlots(av, [], 90, [day])), "16:00 17:30"));
test("slots: 45 + 15 break = every hour", () => assert.equal(show(privateSlots(av, [], 45, [day], 15)), "16:00 17:00 18:00 19:00"));
test("slots: next free time starts when a longer booking ends", () =>
  assert.equal(show(privateSlots(av, [busyAt("16:00", 90)], 60, [day])), "16:00x 17:30 18:30"));
test("slots: break is respected around a booking", () =>
  assert.equal(show(privateSlots(av, [busyAt("17:00", 45)], 45, [day], 15)), "16:00 17:00x 18:00 19:00"));
test("slots: whole-day vacation block closes the day", () =>
  assert.equal(show(privateSlots(av, [busyAt("00:00", 1440)], 60, [day])), "16:00x"));
test("slots: two ranges in one day", () =>
  assert.equal(show(privateSlots([{ weekday: 2, start_time: "09:00", end_time: "11:00" }, ...av], [], 60, [day])), "09:00 10:00 16:00 17:00 18:00 19:00"));
test("slots: no availability on other weekdays", () => assert.equal(privateSlots(av, [], 60, ["2026-11-04"]).length, 0));
test("slots: a lesson never runs past the end of the range", () => {
  const s = privateSlots([{ weekday: 2, start_time: "16:00", end_time: "17:30" }], [], 60, [day]);
  assert.equal(show(s), "16:00");
});

test("cleanMobile accepts Israeli mobile formats", () => {
  for (const v of ["0501234567", "050-123 4567", "+972501234567", "972501234567"]) assert.equal(cleanMobile(v), "+972501234567");
});
test("cleanMobile rejects landlines and junk", () => {
  for (const v of ["031234567", "12345", "", "0501234"]) assert.equal(cleanMobile(v), null);
});
test("waLink builds wa.me link with encoded Arabic text", () => {
  const u = new URL(waLink("+972501234567", "مرحباً، حجزت"));
  assert.equal(u.host, "wa.me");
  assert.equal(u.pathname, "/972501234567");
  assert.equal(u.searchParams.get("text"), "مرحباً، حجزت");
  assert.equal(waLink(null, "x"), null);
});
test("googleCalLink uses UTC start/end and lesson length", () => {
  const u = new URL(googleCalLink("رياضيات", iso(fromLocal(day, "16:00")), 45, "حجز"));
  assert.equal(u.searchParams.get("dates"), "20261103T140000Z/20261103T144500Z");
});
test("icsFile is valid, escapes commas and has a 1-hour alarm", () => {
  const ics = icsFile([{ uid: "a", title: "رياضيات, حصة", start: iso(fromLocal(day, "16:00")), minutes: 60, details: "سطر1\nسطر2" }]);
  assert.match(ics, /^BEGIN:VCALENDAR\r\n/);
  assert.match(ics, /DTSTART:20261103T140000Z/);
  assert.match(ics, /DTEND:20261103T150000Z/);
  assert.match(ics, /SUMMARY:رياضيات\\, حصة/);
  assert.match(ics, /DESCRIPTION:سطر1\\nسطر2/);
  assert.match(ics, /TRIGGER:-PT1H/);
  assert.match(ics, /END:VCALENDAR$/);
});
