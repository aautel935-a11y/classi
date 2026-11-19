// v3 ledger helpers: amount parsing, CSV export (injection-safe, carries the notice), totals.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const L = require(`${process.env.CLASSI_LIB}/ledger.js`);

test("parseAmount accepts what people type and refuses the rest", () => {
  assert.equal(L.parseAmount("150"), 150);
  assert.equal(L.parseAmount("150.5"), 150.5);
  assert.equal(L.parseAmount("1,250.75"), 1250.75);
  assert.equal(L.parseAmount("₪ 90"), 90);
  for (const bad of ["", "0", "-5", "1.234", "abc", "1,25", "2000000", "1e3", "12,34,567", null, undefined]) {
    assert.equal(L.parseAmount(bad), null, String(bad));
  }
});

test("parseDay keeps only real calendar days", () => {
  assert.equal(L.parseDay("2026-11-20"), "2026-11-20");
  assert.equal(L.parseDay("2026-02-30"), null);
  assert.equal(L.parseDay("20/11/2026"), null);
  assert.equal(L.parseDay(""), null);
});

test("money shows decimals only when needed", () => {
  assert.equal(L.money(1250), "1,250 ₪");
  assert.equal(L.money(1250.5), "1,250.50 ₪");
});

test("CSV cells cannot become spreadsheet formulas", () => {
  for (const evil of ["=HYPERLINK(\"http://x\")", "+1+1", "-2+3", "@SUM(A1)", "\t=1"]) {
    assert.match(L.csvCell(evil), /^"'/, evil);
  }
  assert.equal(L.csvCell('a "quoted" name'), '"a ""quoted"" name"');
  assert.equal(L.csvCell(null), '""');
});

test("charges CSV starts with a BOM and the notice, one row per charge", () => {
  const csv = L.chargesCsv([
    { id: "1", customer_label: "=cmd", customer_id: null, description: "حصة", source_kind: "manual", source_id: null, amount: 100,
      deposit_amount: null, paid: 40, remaining: 60, status: "partial", due_on: "2026-11-30", created_at: "2026-11-20T10:00:00Z", cancel_reason: null },
  ]);
  assert.ok(csv.startsWith("﻿"));
  const lines = csv.slice(1).trim().split("\r\n");
  assert.equal(lines.length, 3);
  assert.match(lines[0], /Classi لا يستلم الأموال/);
  assert.match(lines[2], /^"'=cmd"/);
  assert.match(lines[2], /مدفوع جزئياً/);
});

test("totals leave cancelled charges out", () => {
  const t = L.totals([
    { amount: 100, paid: 40, remaining: 60, status: "overdue" },
    { amount: 50, paid: 50, remaining: 0, status: "paid" },
    { amount: 999, paid: 0, remaining: 999, status: "cancelled" },
  ]);
  assert.deepEqual(t, { charged: 150, paid: 90, remaining: 60, overdue: 60, open: 1 });
});

test("the notice says the status is the business's record, not a bank or tax document", () => {
  assert.match(L.LEDGER_NOTICE, /صاحب العمل/);
  assert.match(L.LEDGER_NOTICE, /لا يستلم الأموال/);
  assert.match(L.LEDGER_NOTICE, /ليس مستنداً ضريبياً/);
});
