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
  return [...byId.values()].sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id.localeCompare(b.id));
}

/** The newest real (non-temporary) message time, for "give me what came after". */
export function lastStamp(msgs: Msg[]): string | null {
  for (let i = msgs.length - 1; i >= 0; i--) if (!msgs[i].id.startsWith("tmp-")) return msgs[i].created_at;
  return null;
}

/** The oldest message time, for "load older". */
export const firstStamp = (msgs: Msg[]) => (msgs.length ? msgs[0].created_at : null);
