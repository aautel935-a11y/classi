// PostgREST refuses an embed when two tables are linked in more than one way (PGRST201) and the page then
// silently shows nothing. bookings and sessions are linked directly and through attendance / lesson_reports,
// so every embed between them must name the foreign key. Usage: node tests/check-embeds.mjs
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const files = [];
const walk = (d) => { for (const f of readdirSync(d)) { const p = join(d, f); if (statSync(p).isDirectory()) { if (!["node_modules", ".next"].includes(f)) walk(p); } else if (/\.(ts|tsx)$/.test(f)) files.push(p); } };
["app", "lib", "components"].forEach((d) => walk(join(root, d)));

const rules = [
  { from: "bookings", embed: /(^|[,(:\s])sessions\(/ },
  { from: "sessions", embed: /(^|[,(:\s])bookings\(/ },
];
let bad = 0;
for (const f of files) {
  readFileSync(f, "utf8").split("\n").forEach((line, i) => {
    for (const r of rules) {
      if (line.includes(`from("${r.from}")`) && r.embed.test(line)) {
        console.log(`FAIL: ${f.slice(root.length)}:${i + 1} embeds ${r.from === "bookings" ? "sessions" : "bookings"} without a foreign-key hint (use !bookings_session_id_fkey)`);
        bad++;
      }
    }
  });
}
console.log(bad ? `${bad} ambiguous embed(s)` : `embeds: ok (${files.length} files)`);
process.exit(bad ? 1 : 0);
