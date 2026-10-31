// Supabase's API returns at most 1,000 rows per request (max_rows). Lists that can grow past that are read in
// pages until a short page arrives. The query must have a stable order (end it with a unique column).
type Page<T> = PromiseLike<{ data: T[] | null; error: { message: string } | null }>;

export async function fetchAll<T>(page: (from: number, to: number) => Page<T>, size = 1000, max = 50_000): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; from < max; from += size) {
    const { data, error } = await page(from, from + size - 1);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if (!data || data.length < size) break;
  }
  return out;
}
