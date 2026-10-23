"use client";

import { useState, useTransition } from "react";
import { rescheduleAction } from "@/app/actions";

type Props = {
  path: string;
  session: { id: string; seq: number; day: string; time: string; roomId: string | null };
  rooms: { id: string; name: string }[];
  laterCount: number;
  students: number;
};

const TIMES = Array.from({ length: 21 }, (_, i) => {
  const m = 12 * 60 + i * 30;
  return `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
});

export function EditSession({ path, session, rooms, laterCount, students }: Props) {
  const [open, setOpen] = useState(false);
  const [day, setDay] = useState(session.day);
  const [tm, setTm] = useState(session.time);
  const [room, setRoom] = useState(session.roomId ?? "");
  const [scope, setScope] = useState<"one" | "following">("one");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const times = TIMES.includes(session.time) ? TIMES : [session.time, ...TIMES];

  function save() {
    setError(null);
    start(async () => {
      const r = await rescheduleAction({ sessionId: session.id, day, time: tm, roomId: room || null, scope, reason, path });
      if (r.error) return setError(r.error);
      setDone(`تم تعديل ${r.count === 1 ? "اللقاء" : `${r.count} لقاءات`}، وأُبلغ المعلم والطلاب وأولياء أمورهم.`);
      setTimeout(() => { setOpen(false); setDone(null); }, 1800);
    });
  }

  return (
    <>
      <button className="btn sm ghost" onClick={() => setOpen(true)}>تعديل</button>
      {open && (
        <>
          <div className="scrim" onClick={() => setOpen(false)} />
          <div className="sheet" dir="rtl" role="dialog" aria-modal="true" aria-label="تعديل الموعد">
            <div className="grab" />
            <div className="wrap">
              <h2>تعديل اللقاء {session.seq}</h2>
              <div className="typeform">
                <label className="field" htmlFor={`d-${session.id}`}>التاريخ<input id={`d-${session.id}`} type="date" value={day} onChange={(e) => setDay(e.target.value)} /></label>
                <label className="field" htmlFor={`t-${session.id}`}>الساعة<select id={`t-${session.id}`} value={tm} onChange={(e) => setTm(e.target.value)}>{times.map((t) => <option key={t}>{t}</option>)}</select></label>
                {rooms.length > 0 && (
                  <label className="field" htmlFor={`r-${session.id}`}>القاعة<select id={`r-${session.id}`} value={room} onChange={(e) => setRoom(e.target.value)}>{rooms.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select></label>
                )}
              </div>
              <button className="opt" aria-pressed={scope === "one"} onClick={() => setScope("one")}><span className="dot" /><span>هذا اللقاء فقط</span></button>
              <button className="opt" aria-pressed={scope === "following"} onClick={() => setScope("following")}>
                <span className="dot" />
                <span>هذا اللقاء وكل اللقاءات بعده <span className="muted small num">({laterCount} لقاء)</span></span>
              </button>
              <label className="field" htmlFor={`why-${session.id}`}>رسالة للطلاب (اختياري)<input id={`why-${session.id}`} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="مثلاً: بسبب امتحان في المدارس" /></label>
              {error && <p className="err">{error}</p>}
              {done && <p className="okmsg">{done}</p>}
              <div className="row">
                <button className="btn ghost" onClick={() => setOpen(false)}>إلغاء</button>
                <button className="btn" style={{ flex: 1 }} disabled={pending} onClick={save}>{pending ? "جارٍ الحفظ…" : `حفظ وإبلاغ ${students} طلاب والمعلم`}</button>
              </div>
            </div>
          </div>
        </>
      )}
    </>
  );
}
