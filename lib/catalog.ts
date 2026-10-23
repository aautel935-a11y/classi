import { createClient } from "./supabase/server";
import { OFFERING_SELECT, type Offering } from "./types";

export async function loadCatalog() {
  const supabase = await createClient();
  const [{ data: offerings }, { data: seats }, { data: subjects }, { data: levels }] = await Promise.all([
    supabase.from("offerings").select(OFFERING_SELECT).eq("active", true).order("created_at"),
    supabase.rpc("seats_overview"),
    supabase.from("subjects").select("id,name").order("id"),
    supabase.from("levels").select("id,name").order("sort"),
  ]);
  return {
    offerings: ((offerings ?? []) as unknown as Offering[]).filter((o) => o.teacher || o.institute),
    taken: courseSeats((seats ?? []) as SeatRow[]),
    subjects: (subjects ?? []) as { id: number; name: string }[],
    levels: (levels ?? []) as { id: number; name: string }[],
  };
}

type SeatRow = { offering_id: string; session_id: string | null; taken: number };

/** Courses: total enrolled. Groups: the fullest upcoming session is not useful in lists, so use the first. */
function courseSeats(rows: SeatRow[]) {
  const m = new Map<string, number>();
  for (const r of rows) if (!r.session_id) m.set(r.offering_id, (m.get(r.offering_id) ?? 0) + r.taken);
  return m;
}
