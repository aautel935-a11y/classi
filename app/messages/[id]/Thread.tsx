"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { createClient } from "@/lib/supabase/client";
import { sendMessageAction } from "@/app/actions";
import { dayLong, isoDay, time } from "@/lib/format";
import { PAGE_SIZE, firstStamp, lastStamp, mergeMessages, type Msg } from "@/lib/messages";

const COLS = "id,sender_id,body,created_at,read_at";

/**
 * The conversation: opens on the newest messages, loads older ones on demand, and every few seconds fetches only
 * what arrived since the last message (plus read receipts of my own unread messages). BUG-03.
 */
export function Thread({ conversationId, me, initial, hasOlder: hasOlder0, canWrite }: { conversationId: string; me: string; initial: Msg[]; hasOlder: boolean; canWrite: boolean }) {
  const [msgs, setMsgs] = useState<Msg[]>(initial);
  const [hasOlder, setHasOlder] = useState(hasOlder0);
  const [loadingOlder, setLoadingOlder] = useState(false);
  const msgsRef = useRef<Msg[]>(initial);
  msgsRef.current = msgs;
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const end = useRef<HTMLDivElement>(null);

  // Scroll to the bottom when a newer message arrives, not when older ones are added above.
  const lastId = msgs.length ? msgs[msgs.length - 1].id : "";
  useEffect(() => {
    end.current?.scrollIntoView({ block: "end" });
  }, [lastId]);

  useEffect(() => {
    const supabase = createClient();
    let alive = true;
    async function poll() {
      if (document.hidden) return;
      const cur = msgsRef.current ?? [];
      const since = lastStamp(cur);
      let q = supabase.from("messages").select(COLS).eq("conversation_id", conversationId).order("created_at").limit(100);
      if (since) q = q.gt("created_at", since);
      const unreadMine = cur.filter((m) => m.sender_id === me && !m.read_at && !m.id.startsWith("tmp-")).map((m) => m.id).slice(-50);
      const [{ data }, { data: receipts }] = await Promise.all([
        q,
        unreadMine.length ? supabase.from("messages").select(COLS).in("id", unreadMine).not("read_at", "is", null) : Promise.resolve({ data: [] as Msg[] }),
      ]);
      if (!alive) return;
      const incoming = [...((data ?? []) as Msg[]), ...((receipts ?? []) as Msg[])];
      if (incoming.length) setMsgs((m) => mergeMessages(m, incoming));
      if (((data ?? []) as Msg[]).some((m) => m.sender_id !== me && !m.read_at)) await supabase.rpc("mark_conversation_read", { p_conv: conversationId });
    }
    const t = setInterval(poll, 4000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [conversationId, me]);

  async function loadOlder() {
    const before = firstStamp(msgsRef.current ?? []);
    if (!before) return;
    setLoadingOlder(true);
    const { data } = await createClient().from("messages").select(COLS).eq("conversation_id", conversationId)
      .lt("created_at", before).order("created_at", { ascending: false }).limit(PAGE_SIZE);
    setLoadingOlder(false);
    const older = ((data ?? []) as Msg[]).slice().reverse();
    setHasOlder(older.length === PAGE_SIZE);
    if (older.length) setMsgs((m) => mergeMessages(m, older));
  }

  function send(e: React.FormEvent) {
    e.preventDefault();
    const body = text.trim();
    if (!body) return;
    setError(null);
    const temp: Msg = { id: `tmp-${Date.now()}`, sender_id: me, body, created_at: new Date().toISOString(), read_at: null };
    setMsgs((m) => [...m, temp]);
    setText("");
    start(async () => {
      const r = await sendMessageAction(conversationId, body);
      if (r.error) {
        setError(r.error);
        setMsgs((m) => m.filter((x) => x.id !== temp.id));
        setText(body);
      }
    });
  }

  let lastDay = "";
  return (
    <>
      <div className="bubbles" aria-live="polite">
        {hasOlder && (
          <button type="button" className="btn sm ghost" style={{ alignSelf: "center" }} onClick={loadOlder} disabled={loadingOlder}>
            {loadingOlder ? "لحظة…" : "عرض الرسائل الأقدم"}
          </button>
        )}
        {msgs.length === 0 && <p className="empty">اكتب أول رسالة. مثلاً: هل يناسبك يوم الثلاثاء؟</p>}
        {msgs.map((m) => {
          const day = isoDay(m.created_at);
          const showDay = day !== lastDay;
          lastDay = day;
          const mine = m.sender_id === me;
          return (
            <div key={m.id} style={{ display: "contents" }}>
              {showDay && <div className="day-sep">{dayLong(m.created_at)}</div>}
              <div className={`bubble ${mine ? "me" : "them"}`}>
                <span style={{ whiteSpace: "pre-wrap" }}>{m.body}</span>
                <span className="stamp num">
                  {time(m.created_at)}
                  {mine && (m.id.startsWith("tmp-") ? " · يُرسل" : m.read_at ? " · قُرئت" : "")}
                </span>
              </div>
            </div>
          );
        })}
        <div ref={end} />
      </div>
      {canWrite && (
        <form className="composer sticky-composer" onSubmit={send}>
          <textarea
            id="msg"
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                (e.currentTarget.form as HTMLFormElement).requestSubmit();
              }
            }}
            rows={1}
            maxLength={2000}
            placeholder="اكتب رسالة"
            aria-label="اكتب رسالة"
          />
          <button className="btn sm" type="submit" disabled={pending || !text.trim()}>إرسال</button>
        </form>
      )}
      {error && <p className="err">{error}</p>}
    </>
  );
}
