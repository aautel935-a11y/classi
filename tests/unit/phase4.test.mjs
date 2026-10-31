// Phase 4: search arguments (the database filter must receive exactly what the page's filter meant) and paging.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const dir = process.env.CLASSI_LIB;
const { searchArgs, matchesOffer, SEARCH_PAGE } = require(`${dir}/search.js`);
const { fetchAll } = require(`${dir}/fetch-all.js`);

test("searchArgs: empty filters search everything, first page", () => {
  assert.deepEqual(searchArgs({}), { p_type: null, p_place: null, p_subject: null, p_level: null, p_town: null, p_q: null, p_limit: SEARCH_PAGE, p_offset: 0 });
});
test("searchArgs: query is trimmed; blank means no text filter", () => {
  assert.equal(searchArgs({ q: "  فيزياء " }).p_q, "فيزياء");
  assert.equal(searchArgs({ q: "   " }).p_q, null);
});
test("searchArgs: ids must be plain numbers, as the old String(id) === value comparison required", () => {
  assert.equal(searchArgs({ subject: "3" }).p_subject, 3);
  assert.equal(searchArgs({ subject: "03" }), null);
  assert.equal(searchArgs({ subject: "x" }), null);
  assert.equal(searchArgs({ level: "1.0" }), null);
});
test("searchArgs: pages", () => {
  assert.equal(searchArgs({}, 3).p_offset, 2 * SEARCH_PAGE);
  assert.equal(searchArgs({}, 0).p_offset, 0);
  assert.equal(searchArgs({}, Number.NaN).p_offset, 0);
});
test("matchesOffer: the original rules (owner required, case-sensitive substring)", () => {
  const o = { title: "Math 101", type: "private", places: ["home"], subject: { id: 1, name: "رياضيات" }, level: null, teacher: { name: "سامر", town: "جت" }, institute: null };
  assert.ok(matchesOffer(o, { q: "Math" }));
  assert.ok(!matchesOffer(o, { q: "math" }));
  assert.ok(matchesOffer(o, { q: "سام", town: "جت", place: "home", subject: "1" }));
  assert.ok(!matchesOffer({ ...o, teacher: null }, {}));
});
test("fetchAll: reads pages until a short one, in order", async () => {
  const rows = Array.from({ length: 2345 }, (_, i) => i);
  const seen = [];
  const all = await fetchAll((a, b) => { seen.push([a, b]); return Promise.resolve({ data: rows.slice(a, b + 1), error: null }); });
  assert.equal(all.length, 2345);
  assert.deepEqual(all.slice(998, 1002), [998, 999, 1000, 1001]);
  assert.deepEqual(seen, [[0, 999], [1000, 1999], [2000, 2999]]);
});
test("fetchAll: an error stops instead of returning a partial list", async () => {
  await assert.rejects(fetchAll(() => Promise.resolve({ data: null, error: { message: "boom" } })), /boom/);
});
