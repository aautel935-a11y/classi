import Link from "next/link";
import { OfferCard } from "@/components/OfferCard";
import { loadReference, searchCatalog } from "@/lib/catalog";
import { SEARCH_PAGE, type SearchFilters } from "@/lib/search";
import { PLACES, TOWNS, TYPES, type OfferingType, type Place } from "@/lib/types";
import { HowToBook } from "@/components/HowToBook";
import { AutoSubmit } from "./AutoSubmit";

export const dynamic = "force-dynamic";
type SP = Promise<Record<string, string | undefined>>;

export default async function Search({ searchParams }: { searchParams: SP }) {
  const f = await searchParams;
  const q = (f.q ?? "").trim();
  // Phase 4: the database filters (same rules as before) and returns one page; filters in a fixed order for the cache key.
  const filters: SearchFilters = { type: f.type || undefined, place: f.place || undefined, subject: f.subject || undefined, level: f.level || undefined, town: f.town || undefined, q: q || undefined };
  const page = Math.max(1, Math.min(1000, Number.parseInt(f.page ?? "1", 10) || 1));
  const [{ subjects, levels }, found] = await Promise.all([loadReference(), searchCatalog(filters, page)]);
  const res = found.offers;
  const taken = new Map(found.taken);
  const pages = Math.max(1, Math.ceil(found.total / SEARCH_PAGE));
  const link = (type: string) => {
    const p = new URLSearchParams(Object.entries(f).filter(([k, v]) => v && k !== "type" && k !== "page") as [string, string][]);
    if (type) p.set("type", type);
    return `/search?${p}`;
  };
  const pageLink = (n: number) => {
    const p = new URLSearchParams(Object.entries(f).filter(([k, v]) => v && k !== "page") as [string, string][]);
    if (n > 1) p.set("page", String(n));
    return `/search?${p}`;
  };

  return (
    <div className="wrap">
      <div className="section">
        <h1>بحث</h1>
        <HowToBook />
        <div className="hscroll">
          <Link className="chip" href={link("")} aria-current={!f.type ? "page" : undefined}>
            كل الأنواع
          </Link>
          {(Object.keys(TYPES) as OfferingType[]).map((k) => (
            <Link key={k} className="chip" href={link(k)} aria-current={f.type === k ? "page" : undefined}>
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
        <h2 className="sr-only">النتائج</h2>
        <p className="small muted num" aria-live="polite">{found.total} نتيجة{pages > 1 ? ` · صفحة ${page} من ${pages}` : ""}</p>
        <div className="stack">
          {res.length ? (
            res.map((o) => <OfferCard key={o.id} o={o} taken={o.type === "course" ? taken.get(o.id) ?? 0 : undefined} />)
          ) : (
            <div className="empty">{found.total ? "لا نتائج في هذه الصفحة." : "لا توجد نتائج بهذه الفلاتر. جرّب إزالة المادة أو البلد."}</div>
          )}
        </div>
        {pages > 1 && (
          <nav className="row between" aria-label="صفحات النتائج">
            {page > 1 ? <Link className="btn sm ghost" href={pageLink(page - 1)} rel="prev">السابق</Link> : <span />}
            {page < pages ? <Link className="btn sm ghost" href={pageLink(page + 1)} rel="next">التالي</Link> : <span />}
          </nav>
        )}
      </div>
    </div>
  );
}
