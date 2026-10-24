import { unstable_cache } from "next/cache";
import { publicClient } from "./supabase/public";
import { OFFERING_SELECT, type Offering } from "./types";

type SeatRow = { offering_id: string; session_id: string | null; taken: number };

/**
 * The public catalogue (offers, subjects, levels, seat counts) is the same for
 * every visitor, so it is fetched once and shared for 60 seconds, or refreshed
 * at once when a teacher or institute changes something (tag "catalog").
 */
const fetchCatalog = unstable_cache(
  async () => {
    const supabase = publicClient();
    const [{ data: offerings }, { data: seats }, { data: subjects }, { data: levels }, { data: teachers }] = await Promise.all([
      supabase.from("offerings").select(OFFERING_SELECT).eq("active", true).order("created_at"),
      supabase.rpc("seats_overview"),
      supabase.from("subjects").select("id,name").order("id"),
      supabase.from("levels").select("id,name").order("sort"),
      supabase.from("teachers").select("id,name,town,rating,reviews_count,photo_url,subject:subjects(name)").order("rating", { ascending: false }),
    ]);
    const taken: [string, number][] = [];
    const m = new Map<string, number>();
    for (const r of (seats ?? []) as SeatRow[]) if (!r.session_id) m.set(r.offering_id, (m.get(r.offering_id) ?? 0) + r.taken);
    m.forEach((v, k) => taken.push([k, v]));
    return {
      offerings: ((offerings ?? []) as unknown as Offering[]).filter((o) => o.teacher || o.institute),
      taken,
      subjects: (subjects ?? []) as { id: number; name: string }[],
      levels: (levels ?? []) as { id: number; name: string }[],
      teachers: (teachers ?? []) as any[],
    };
  },
  ["catalog-v1"],
  { revalidate: 60, tags: ["catalog"] }
);

export async function loadCatalog() {
  const c = await fetchCatalog();
  return { ...c, taken: new Map(c.taken) };
}
