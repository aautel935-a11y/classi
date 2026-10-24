"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { createClient } from "@/lib/supabase/client";
import { sendMessageAction } from "@/app/actions";
import { dayLong, isoDay, time } from "@/lib/format";

type Msg = { id: string; sender_id: string; body: string; created_at: string; read_at: string | null };

/** The conversation: checks for new messages every few seconds while open. */
export function Thread({ conversationId, me, initial, canWrite }: { conversationId: string; me: string; initial: Msg[]; canWrite: boolean }) {
  const [msgs, setMsgs] = useState<Msg[]>(initial);
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const end = useRef<HTMLDivElement>(null);

  useEffect(() => {
    end.current?.scrollIntoView({ block: "end" });
  }, [msgs.length]);

  useEffect(() => {
    const supabase = createClient();
    let alive = true;
    async function poll() {
      if (document.hidden) return;
      const { data } = await supabase.from("messages").select("id,sender_id,body,created_at,read_at").eq("conversation_id", conversationId).order("created_at").limit(300);
      if (!alive || !data) return;
      setMsgs(data as Msg[]);
      if ((data as Msg[]).some((m) => m.sender_id !== me && !m.read_at)) await supabase.rpc("mark_conversation_read", { p_conv: conversationId });
    }
    const t = setInterval(poll, 4000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [conversationId, me]);

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
