// Chat thread state (BUG-03): the newest page first, older pages on demand, new messages appended by polling.

export type Msg = { id: string; sender_id: string; body: string; created_at: string; read_at: string | null };

export const PAGE_SIZE = 50;

/**
 * Merge fetched messages into the thread: no duplicates, sorted by time, and an optimistic "tmp-…" message is
 * replaced by the real one (same sender and text) when it arrives.
 */
export function mergeMessages(current: Msg[], incoming: Msg[]): Msg[] {
  const byId = new Map<string, Msg>();
  for (const m of current) byId.set(m.id, m);
  for (const m of incoming) {
    const temp = [...byId.values()].find((x) => x.id.startsWith("tmp-") && x.sender_id === m.sender_id && x.body === m.body);
    if (temp) byId.delete(temp.id);
    byId.set(m.id, { ...byId.get(m.id), ...m });
  }
  // Compare instants, not strings ("…10:00:00+00:00" vs "…10:00:00.5+00:00" sort wrongly as text).
  return [...byId.values()].sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/** The newest real (non-temporary) message time, for "give me what came after". */
export function lastStamp(msgs: Msg[]): string | null {
  for (let i = msgs.length - 1; i >= 0; i--) if (!msgs[i].id.startsWith("tmp-")) return msgs[i].created_at;
  return null;
}

/**
 * Polling cursor: a little before the last message, so messages with the same timestamp, or written by a
 * transaction that committed slightly later, are not skipped. mergeMessages drops the overlap.
 */
export function pollFrom(msgs: Msg[], overlapMs = 10000): string | null {
  const last = lastStamp(msgs);
  return last ? new Date(Date.parse(last) - overlapMs).toISOString() : null;
}

/** The oldest message time, for "load older". */
export const firstStamp = (msgs: Msg[]) => (msgs.length ? msgs[0].created_at : null);
