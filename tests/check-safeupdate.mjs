// Supabase runs pg_safeupdate for API requests: UPDATE or DELETE without WHERE fails at run time, also inside
// functions. This check reads every migration and fails on such a statement, unless a later migration redefines
// the function it belongs to. Usage: node tests/check-safeupdate.mjs
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const dir = new URL("../supabase/migrations/", import.meta.url).pathname;
const files = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();
const text = files.map((f) => readFileSync(join(dir, f), "utf8"));
const fnRe = /function\s+public\.(\w+)\s*\(/gi;
const definedAfter = (name, i) => text.slice(i + 1).some((t) => new RegExp(`function\\s+public\\.${name}\\s*\\(`, "i").test(t));

let bad = 0;
text.forEach((src, i) => {
  const clean = src.replace(/--[^\n]*/g, (m) => " ".repeat(m.length));
  for (const m of clean.matchAll(/(^|[\s;(])(delete\s+from|update)\s+[^;]*;/gim)) {
    const st = m[0];
    // Only real statements: the word before must end a previous statement or open a block.
    const prev = (clean.slice(0, m.index + m[1].length).match(/(\S+)\s*$/) ?? [, ""])[1].toLowerCase();
    if (prev && !/(;|begin|then|else|loop|\$\$|\(|as)$/.test(prev)) continue;
    if (/^\s*update/i.test(st.trim()) && /\bdo\s+update\s*$/i.test(clean.slice(Math.max(0, m.index - 20), m.index + m[1].length + 6))) continue;
    if (/\bwhere\b/i.test(st)) continue;
    if (/^\W*update\s+set\b/i.test(st)) continue;           // ON CONFLICT ... DO UPDATE SET
    if (/^\W*update\s+(of|on)\b/i.test(st)) continue;        // trigger definitions
    const before = clean.slice(0, m.index);
    const fn = [...before.matchAll(fnRe)].pop()?.[1];
    if (fn && definedAfter(fn, i)) continue;
    const line = before.split("\n").length;
    console.log(`FAIL: ${files[i]}:${line} ${fn ? `(${fn}) ` : ""}${st.trim().replace(/\s+/g, " ").slice(0, 100)}`);
    bad++;
  }
});
console.log(bad ? `${bad} statement(s) without WHERE` : `safeupdate: ok (${files.length} migrations)`);
process.exit(bad ? 1 : 0);
