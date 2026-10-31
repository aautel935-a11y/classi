import { unstable_cache } from "next/cache";
import { publicClient } from "./supabase/public";
import { OFFERING_SELECT, type Offering } from "./types";
import { searchArgs, type SearchFilters } from "./search";

// Public catalogue data, the same for every visitor, shared for 60 seconds or refreshed at once when a teacher or
// institute changes something (tag "catalog"). Phase 4: no more loading of the whole catalogue (it passed the
// 1,000-row API limit and Next's 2 MB cache entry limit at growth size); each page asks for what it shows.

/** Subjects and levels (small, rarely change). */
export const loadReference = unstable_cache(
  async () => {
    const db = publicClient();
    const [{ data: subjects }, { data: levels }] = await Promise.all([
      db.from("subjects").select("id,name").order("id"),
      db.from("levels").select("id,name").order("sort"),
    ]);
    return { subjects: (subjects ?? []) as { id: number; name: string }[], levels: (levels ?? []) as { id: number; name: string }[] };
  },
  ["reference-v1"],
  { revalidate: 3600, tags: ["catalog"] }
);

/** Seats taken in courses, for the offers given. */
async function courseSeats(ids: string[]): Promise<[string, number][]> {
  if (!ids.length) return [];
  const { data } = await publicClient().rpc("course_seats", { p_offerings: ids });
  return ((data ?? []) as { offering_id: string; taken: number }[]).map((r) => [r.offering_id, r.taken]);
}

/** Home page: the 8 best-rated teachers of a town and the next 3 courses that start today or later. */
export const loadHome = unstable_cache(
  async (town: string) => {
    const db = publicClient();
    const today = new Date().toISOString().slice(0, 10);
    const [{ data: teachers }, { data: upcoming }] = await Promise.all([
      db.from("teachers").select("id,name,town,rating,reviews_count,photo_url,subject:subjects(name)").eq("town", town)
        .order("rating", { ascending: false }).limit(8),
      db.from("offerings").select(OFFERING_SELECT).eq("active", true).eq("type", "course").gte("start_date", today)
        .order("start_date").order("created_at").limit(12),
    ]);
    const courses = ((upcoming ?? []) as unknown as Offering[]).filter((o) => o.teacher || o.institute).slice(0, 3);
    return { teachers: (teachers ?? []) as any[], courses, taken: await courseSeats(courses.map((o) => o.id)) };
  },
  ["home-v1"],
  { revalidate: 60, tags: ["catalog"] }
);

/** One page of search results (filters as in the address), with the total count. */
export const searchCatalog = unstable_cache(
  async (f: SearchFilters, page: number) => {
    const args = searchArgs(f, page);
    if (!args) return { offers: [] as Offering[], total: 0, taken: [] as [string, number][] };
    const db = publicClient();
    const { data: hits, error } = await db.rpc("search_offers", args);
    if (error) throw new Error(error.message);
    const rows = (hits ?? []) as { id: string; total: number }[];
    const ids = rows.map((r) => r.id);
    const total = rows.length ? Number(rows[0].total) : 0;
    if (!ids.length) {
      // past the last page: still report how many results exist
      if (page > 1) {
        const { data: first } = await db.rpc("search_offers", { ...args, p_limit: 1, p_offset: 0 });
        return { offers: [] as Offering[], total: Number(((first ?? []) as { total: number }[])[0]?.total ?? 0), taken: [] as [string, number][] };
      }
      return { offers: [] as Offering[], total: 0, taken: [] as [string, number][] };
    }
    const { data } = await db.from("offerings").select(OFFERING_SELECT).in("id", ids);
    const byId = new Map(((data ?? []) as unknown as Offering[]).map((o) => [o.id, o]));
    const offers = ids.map((id) => byId.get(id)).filter((o): o is Offering => !!o);
    return { offers, total, taken: await courseSeats(offers.filter((o) => o.type === "course").map((o) => o.id)) };
  },
  ["search-v1"],
  { revalidate: 60, tags: ["catalog"] }
);
