import { Icon } from "@/components/Icon";
import { respondWaitlistAction } from "@/app/actions";
import { dayLong } from "@/lib/format";

export type WRow = { id: string; offering_id: string; offering_title: string; offering_type: string; student_name: string; note: string | null; status: string; pos: number; created_at: string };

const ACCEPT: Record<string, string> = { course: "افتح له مقعداً", group: "أضفه للقاء القادم", private: "ردّ وحدّد موعداً" };

/** The waiting list as the teacher or institute sees it, in order, with answer buttons. */
export function WaitlistOwner({ rows, back, showTitle = true, canAnswer = true, flash, error }: { rows: WRow[]; back: string; showTitle?: boolean; canAnswer?: boolean; flash?: string; error?: string }) {
  if (rows.length === 0 && !flash && !error) return null;
  return (
    <section className="section" id="waitlist">
      <h2>قائمة الانتظار {rows.length > 0 && <span className="badge num">{rows.length}</span>}</h2>
      {error && <p className="err">{error}</p>}
      {flash === "accepted" && <p className="okmsg">تم. وصل الطالب إشعار بأن له مكاناً.</p>}
      {flash === "declined" && <p className="okmsg">أُبلغ الطالب بالاعتذار.</p>}
      {rows.length > 0 && (
        <p className="note"><Icon name="bell" />عندما يُلغى حجز أو تزيد المقاعد أو تضيف أوقاتاً، يصل إشعار تلقائي لأول شخص في القائمة.</p>
      )}
      {rows.map((w) => (
        <div key={w.id} className="card">
          <div className="row between">
            <b>{w.pos}. {w.student_name}</b>
            <span className={`badge ${w.status === "notified" ? "ok" : ""}`}>{w.status === "notified" ? "أُبلغ بمكان فارغ" : "ينتظر"}</span>
          </div>
          {showTitle && <p className="small">{w.offering_title}</p>}
          <p className="small muted">انضم {dayLong(w.created_at)}</p>
          {w.note && <p className="small">«{w.note}»</p>}
          {canAnswer && (
            <div className="stack" style={{ gap: 8 }}>
              <form action={respondWaitlistAction} className="row" style={{ flexWrap: "wrap" }}>
                <input type="hidden" name="id" value={w.id} />
                <input type="hidden" name="back" value={back} />
                <input type="hidden" name="accept" value="1" />
                {w.offering_type === "private" && <input className="inline-input" name="reply" placeholder="رسالة له، مثلاً: عندي مكان الخميس 18:00" maxLength={300} style={{ flex: 1, minWidth: 180 }} />}
                <button className="btn sm okb">{ACCEPT[w.offering_type] ?? "قبول"}</button>
              </form>
              <details>
                <summary className="link small" style={{ color: "var(--bad)" }}>اعتذار</summary>
                <form action={respondWaitlistAction} className="row" style={{ marginTop: 6, flexWrap: "wrap" }}>
                  <input type="hidden" name="id" value={w.id} />
                  <input type="hidden" name="back" value={back} />
                  <input type="hidden" name="accept" value="0" />
                  <input className="inline-input" name="reply" placeholder="سبب أو اقتراح (اختياري)" maxLength={300} style={{ flex: 1, minWidth: 180 }} />
                  <button className="btn sm badb">إرسال الاعتذار</button>
                </form>
              </details>
            </div>
          )}
        </div>
      ))}
    </section>
  );
}
