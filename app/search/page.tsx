import Link from "next/link";
import { OfferCard } from "@/components/OfferCard";
import { loadCatalog } from "@/lib/catalog";
import { PLACES, TOWNS, TYPES, ownerOf, type OfferingType, type Place } from "@/lib/types";
import { AutoSubmit } from "./AutoSubmit";

export const dynamic = "force-dynamic";
type SP = Promise<Record<string, string | undefined>>;

export default async function Search({ searchParams }: { searchParams: SP }) {
  const f = await searchParams;
  const { offerings, taken, subjects, levels } = await loadCatalog();
  const q = (f.q ?? "").trim();
  const res = offerings.filter(
    (o) =>
      (!f.type || o.type === f.type) &&
      (!f.place || o.places.includes(f.place as Place)) &&
      (!f.subject || String(o.subject?.id) === f.subject) &&
      (!f.level || String(o.level?.id) === f.level) &&
      (!f.town || ownerOf(o).town === f.town) &&
      (!q || [o.title, ownerOf(o).name, o.subject?.name].some((s) => s?.includes(q)))
  );
  const link = (type: string) => {
    const p = new URLSearchParams(Object.entries(f).filter(([k, v]) => v && k !== "type") as [string, string][]);
    if (type) p.set("type", type);
    return `/search?${p}`;
  };

  return (
    <div className="wrap">
      <div className="section">
        <h1>بحث</h1>
        <div className="hscroll">
          <Link className="chip" href={link("")} aria-pressed={!f.type}>
            كل الأنواع
          </Link>
          {(Object.keys(TYPES) as OfferingType[]).map((k) => (
            <Link key={k} className="chip" href={link(k)} aria-pressed={f.type === k}>
              {TYPES[k].name}
            </Link>
          ))}
        </div>
        <form className="formstack" action="/search" id="filters">
          {f.type && <input type="hidden" name="type" value={f.type} />}
          <label className="field" htmlFor="q">
            بحث بالاسم أو الموضوع
            <input id="q" name="q" defaultValue={q} placeholder="مثلاً: فيزياء، سامر، النخبة" />
          </label>
          <div className="filters">
            <label className="field" htmlFor="subject">
              المادة
              <select id="subject" name="subject" defaultValue={f.subject ?? ""}>
                <option value="">الكل</option>
                {subjects.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="field" htmlFor="level">
              المرحلة والمنهاج
              <select id="level" name="level" defaultValue={f.level ?? ""}>
                <option value="">الكل</option>
                {levels.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="field" htmlFor="place">
              المكان
              <select id="place" name="place" defaultValue={f.place ?? ""}>
                <option value="">الكل</option>
                {(Object.keys(PLACES) as Place[]).map((k) => (
                  <option key={k} value={k}>
                    {PLACES[k]}
                  </option>
                ))}
              </select>
            </label>
            <label className="field" htmlFor="town">
              البلد
              <select id="town" name="town" defaultValue={f.town ?? ""}>
                <option value="">الكل</option>
                {TOWNS.map((t) => (
                  <option key={t}>{t}</option>
                ))}
              </select>
            </label>
          </div>
          <AutoSubmit formId="filters" />
          <noscript>
            <button className="btn block">بحث</button>
          </noscript>
        </form>
        <p className="small muted num">{res.length} نتيجة</p>
        <div className="stack">
          {res.length ? (
            res.map((o) => <OfferCard key={o.id} o={o} taken={o.type === "course" ? taken.get(o.id) ?? 0 : undefined} />)
          ) : (
            <div className="empty">لا توجد نتائج بهذه الفلاتر. جرّب إزالة المادة أو البلد.</div>
          )}
        </div>
      </div>
    </div>
  );
}
