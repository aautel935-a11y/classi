// Proves that search_offers (database, phase 4) returns exactly what the page's original filter returned:
// same offers, same order, same count, for hundreds of filter combinations, as a visitor (row security on).
// Needs a local database loaded with supabase/tests/perf_data.sql. Never point it at a real project.
//   DB=ct_perf node --experimental-strip-types tests/search-equivalence.mjs
import { execFileSync } from "node:child_process";
import { matchesOffer, searchArgs } from "../lib/search.ts";

const db = process.env.DB || "ct_perf";
const host = process.env.PGSOCK || "/var/tmp/pgc", port = process.env.PGPORT || "54329";
if (/supabase\.co/.test(host)) throw new Error("local databases only");
const psql = (sql) => execFileSync("psql", ["-h", host, "-p", port, "-U", "postgres", "-d", db, "-At", "-v", "ON_ERROR_STOP=1"], { input: sql, maxBuffer: 1 << 28 }).toString();

// 1. What the page used to load: every active offer a visitor can see, with the embeds it filtered on (catalog order).
const offers = JSON.parse(psql(`set role anon;
select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]') from (
  select o.id, o.created_at, o.title, o.type, o.places,
         (select json_build_object('id', s.id, 'name', s.name) from subjects s where s.id = o.subject_id) as subject,
         (select json_build_object('id', l.id) from levels l where l.id = o.level_id) as level,
         (select json_build_object('name', t.name, 'town', t.town) from teachers t where t.id = o.teacher_id) as teacher,
         (select json_build_object('name', i.name, 'town', i.town) from institutes i where i.id = o.institute_id) as institute
    from offerings o where o.active) x;`).trim().split("\n").pop());
if (offers.length < 1000) throw new Error(`expected a large catalogue, got ${offers.length} offers`);

// 2. Filter combinations: every single filter value, odd values, substrings of real titles / names / subjects, pairs.
const uniq = (a) => [...new Set(a)];
const subjects = uniq(offers.map((o) => o.subject?.id).filter(Boolean)).map(String);
const levels = uniq(offers.map((o) => o.level?.id).filter(Boolean)).map(String);
const towns = uniq(offers.map((o) => (o.teacher ?? o.institute)?.town).filter(Boolean));
const words = uniq(offers.flatMap((o) => [o.title, (o.teacher ?? o.institute)?.name, o.subject?.name]).filter(Boolean)
  .flatMap((s) => [s, s.slice(0, 3), s.slice(-2), s.split(" ")[0]]));
let seed = 7; const rnd = (a) => a[(seed = (seed * 48271) % 2147483647) % a.length];
const combos = [{}, { q: "   " }, { q: "%" }, { q: "_" }, { q: "لا يوجد شيء كهذا" }, { type: "x" }, { place: "moon" }, { subject: "01" }, { subject: "abc" }, { level: "1.0" }];
for (const type of ["private", "group", "course", "recorded"]) combos.push({ type });
for (const place of ["home", "online", "center"]) combos.push({ place });
for (const subject of subjects) combos.push({ subject });
for (const level of levels) combos.push({ level });
for (const town of towns) combos.push({ town });
for (let i = 0; i < 120; i++) combos.push({ q: rnd(words) });
for (let i = 0; i < 250; i++) {
  const c = {};
  if (i % 2) c.type = rnd(["private", "group", "course", "recorded"]);
  if (i % 3 === 0) c.place = rnd(["home", "online", "center"]);
  if (i % 4 === 0) c.subject = rnd(subjects);
  if (i % 5 === 0) c.town = rnd(towns);
  if (i % 3 === 1) c.q = rnd(words);
  if (i % 7 === 0 && levels.length) c.level = rnd(levels);
  combos.push(c);
}

// 3. The database side: page through search_offers (100 per page) for each combination, in one psql session.
const lit = (v) => (v === null ? "null" : typeof v === "number" ? String(v) : `'${String(v).replace(/'/g, "''")}'`);
const calls = combos.map((f, i) => {
  const a = searchArgs(f);
  if (!a) return `select ${i} || '|null';`;
  return `select ${i} || '|' || pg_temp.perf_all(${lit(a.p_type)}::text, ${lit(a.p_place)}::text, ${lit(a.p_subject)}::int, ${lit(a.p_level)}::int, ${lit(a.p_town)}::text, ${lit(a.p_q)}::text);`;
}).join("\n");
const out = psql(`
create or replace function pg_temp.perf_all(a text, b text, c int, d int, e text, q text) returns text language plpgsql as $$
declare ids text[] := '{}'; page text[]; tot bigint; off int := 0;
begin
  loop
    select array_agg(id::text order by n), max(total) into page, tot from search_offers(a, b, c, d, e, q, 100, off) with ordinality r(id, total, n);
    exit when page is null;
    ids := ids || page; off := off + 100;
    exit when array_length(page, 1) < 100;
  end loop;
  return coalesce(tot, 0) || '|' || array_to_string(ids, ',');
end $$;
grant execute on function pg_temp.perf_all(text, text, int, int, text, text) to anon;
set role anon;
${calls}`);

// 4. Compare.
let bad = 0;
const lines = out.trim().split("\n").filter((l) => /^\d+\|/.test(l));
if (lines.length !== combos.length) throw new Error(`expected ${combos.length} results, got ${lines.length}`);
for (const line of lines) {
  const [i, total, ids] = line.split("|");
  const f = combos[Number(i)];
  const want = offers.filter((o) => matchesOffer(o, f)).map((o) => o.id);
  const got = total === "null" ? [] : ids ? ids.split(",") : [];
  const gotTotal = total === "null" ? 0 : Number(total);
  if (want.join() !== got.join() || gotTotal !== want.length) {
    bad++;
    if (bad <= 5) console.log(`FAIL: ${JSON.stringify(f)}: page filter ${want.length} offers, database ${got.length} (total ${gotTotal})`);
  }
}
console.log(bad ? `FAIL: ${bad} of ${combos.length} combinations differ` : `PASS: search_offers matches the original filter in all ${combos.length} combinations (${offers.length} visible offers, same order and count)`);
process.exit(bad ? 1 : 0);
