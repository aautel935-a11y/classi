// Search filters (phase 4: the filtering moved into the database function search_offers, one page at a time).
// matchesOffer is the page's original filter, kept as the reference that tests/search-equivalence.mjs compares
// the database against; searchArgs turns the address's filters into the function's arguments.

export const SEARCH_PAGE = 30;

export type SearchFilters = { type?: string; place?: string; subject?: string; level?: string; town?: string; q?: string };
export type SearchOffer = {
  title: string; type: string; places: string[];
  subject: { id: number; name: string } | null; level: { id: number } | null;
  teacher: { name: string; town: string } | null; institute: { name: string; town: string } | null;
};

/** The original in-page filter (before phase 4). Offers without a visible owner are never listed. */
export function matchesOffer(o: SearchOffer, f: SearchFilters): boolean {
  if (!(o.teacher || o.institute)) return false;
  const owner = (o.teacher ?? o.institute)!;
  const q = (f.q ?? "").trim();
  return (
    (!f.type || o.type === f.type) &&
    (!f.place || o.places.includes(f.place)) &&
    (!f.subject || String(o.subject?.id) === f.subject) &&
    (!f.level || String(o.level?.id) === f.level) &&
    (!f.town || owner.town === f.town) &&
    (!q || [o.title, owner.name, o.subject?.name].some((s) => s?.includes(q)))
  );
}

/** An id filter matches only when it is the plain decimal form of an id ("01" or "x" match nothing, as before). */
const idArg = (v: string | undefined): number | null | false => {
  if (!v) return null;
  const n = Number(v);
  return Number.isSafeInteger(n) && String(n) === v ? n : false;
};

export type SearchArgs = {
  p_type: string | null; p_place: string | null; p_subject: number | null; p_level: number | null;
  p_town: string | null; p_q: string | null; p_limit: number; p_offset: number;
};

/** Arguments for search_offers, or null when the filters can match nothing. page starts at 1. */
export function searchArgs(f: SearchFilters, page = 1): SearchArgs | null {
  const subject = idArg(f.subject), level = idArg(f.level);
  if (subject === false || level === false) return null;
  const q = (f.q ?? "").trim();
  const p = Number.isSafeInteger(page) && page > 0 ? page : 1;
  return {
    p_type: f.type || null, p_place: f.place || null, p_subject: subject, p_level: level,
    p_town: f.town || null, p_q: q || null, p_limit: SEARCH_PAGE, p_offset: (p - 1) * SEARCH_PAGE,
  };
}
