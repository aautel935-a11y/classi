// SEC-26: error text in "?error=" is shown only when the server signed it (lib/flash.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
process.env.FLASH_SECRET = "unit-test-only";
const F = require(`${process.env.CLASSI_LIB}/flash.js`);

const value = (q) => decodeURIComponent(q.replace(/^error=/, ""));

test("a message the server signed is shown as written", () => {
  const q = F.errParam("اكتب مبلغاً صحيحاً أكبر من صفر.");
  assert.match(q, /^error=/);
  assert.equal(F.flashText(value(q)), "اكتب مبلغاً صحيحاً أكبر من صفر.");
});

test("a crafted link cannot put words on a page", () => {
  for (const crafted of ["حسابك موقوف، اتصل بالدعم على الرقم في الأسفل", "x", "AAAAAAAAAAAAAAAAAAAAAA.رسالة مزيفة"]) {
    assert.equal(F.flashText(crafted), F.FLASH_GENERIC, crafted);
  }
});

test("changing the signed text, or reusing a tag for other text, gives the generic line", () => {
  const signed = value(F.errParam("الموعد لم يعد متاحاً"));
  const tag = signed.slice(0, 22);
  assert.equal(F.flashText(signed.replace("متاحاً", "مجانياً")), F.FLASH_GENERIC);
  assert.equal(F.flashText(`${tag}.نص آخر`), F.FLASH_GENERIC);
});

test("signed text still passes the link and phone screen (defence in depth)", () => {
  assert.equal(F.flashText(value(F.errParam("زوروا https://evil.example.com"))), F.FLASH_GENERIC);
  assert.equal(F.flashText(value(F.errParam("اتصل 0521234567"))), F.FLASH_GENERIC);
});

test("no error, no box; arrays take the first value", () => {
  assert.equal(F.flashText(undefined), null);
  assert.equal(F.flashText(""), null);
  assert.equal(F.flashText([value(F.errParam("خطأ"))]), "خطأ");
});

test("SEC-26: no source file builds an unsigned error= link", async () => {
  const { readFileSync, readdirSync, statSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { fileURLToPath } = await import("node:url");
  const root = fileURLToPath(new URL("../../", import.meta.url));
  const bad = [];
  const walk = (d) => { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) walk(p); else if (/\.(ts|tsx)$/.test(n)) {
    const s = readFileSync(p, "utf8"); if (/error=\$\{encodeURIComponent|[?&]error=[^$\s"'`]/.test(s.replace(/^\s*(\/\/|\*).*$/gm, ""))) bad.push(p.slice(root.length)); } } };
  for (const d of ["app", "components"]) walk(join(root, d));
  assert.deepEqual(bad, []);
});
