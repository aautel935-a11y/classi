import { Stars } from "@/components/Icon";
import { replyReviewAction } from "@/app/actions";
import { dayLong } from "@/lib/format";

export type ReviewRow = { id: string; stars: number; body: string | null; author_name: string | null; reply: string | null; created_at: string };

/** Ratings from families who had a lesson, with the teacher's reply. Owners can reply inline. */
export function ReviewsList({ rows, owner = false, back = "/teach#reviews", title = "تقييمات العائلات" }: { rows: ReviewRow[]; owner?: boolean; back?: string; title?: string }) {
  if (!rows.length && !owner) return null;
  return (
    <section className="section" id="reviews">
      <h2>{title}</h2>
      {rows.length === 0 && <div className="empty">لا تقييمات بعد. تصل العائلات رسالة تطلب التقييم بعد الحصة.</div>}
      {rows.map((r) => (
        <div key={r.id} className="card">
          <div className="row between">
            <b>{r.author_name || "ولي أمر"}</b>
            <span className="review-stars" aria-label={`${r.stars} من 5`}>{"★".repeat(r.stars)}<i>{"★".repeat(5 - r.stars)}</i></span>
          </div>
          {r.body && <p>{r.body}</p>}
          <span className="small muted">{dayLong(r.created_at)}</span>
          {r.reply && <p className="review-reply small"><b>ردّ المعلم:</b> {r.reply}</p>}
          {owner && (
            <details>
              <summary className="link small">{r.reply ? "تعديل الرد" : "ردّ على التقييم"}</summary>
              <form action={replyReviewAction} className="row" style={{ marginTop: 6, flexWrap: "wrap" }}>
                <input type="hidden" name="id" value={r.id} />
                <input type="hidden" name="back" value={back} />
                <input className="inline-input" name="reply" maxLength={600} defaultValue={r.reply ?? ""} placeholder="شكراً على التقييم…" style={{ flex: 1, minWidth: 180 }} />
                <button className="btn sm">حفظ</button>
              </form>
            </details>
          )}
        </div>
      ))}
    </section>
  );
}

export { Stars };
