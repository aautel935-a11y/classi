// Run async work with a fixed number in flight, keeping every outcome (used by the notification dispatcher: BUG-22).

export type Outcome<T, R> = { item: T; ok: true; value: R } | { item: T; ok: false; error: string };

export async function runPool<T, R>(items: T[], concurrency: number, work: (item: T) => Promise<R>): Promise<Outcome<T, R>[]> {
  const out: Outcome<T, R>[] = new Array(items.length);
  let next = 0;
  async function lane() {
    while (next < items.length) {
      const i = next++;
      try { out[i] = { item: items[i], ok: true, value: await work(items[i]) }; }
      catch (e) { out[i] = { item: items[i], ok: false, error: e instanceof Error ? e.message : String(e) }; }
    }
  }
  await Promise.all(Array.from({ length: Math.max(1, Math.min(concurrency, items.length)) }, lane));
  return out;
}
