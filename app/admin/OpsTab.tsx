import Link from "next/link";
import { adminCancelBookingAction, adminSetPaymentAction } from "@/app/actions";
import { dayLong, time } from "@/lib/format";
import { PAY_STATUS } from "@/components/Pay";

type Stats = {
  bookings_7d: number; bookings_prev7d: number; lessons_7d: number; cancelled_7d: number; new_users_7d: number; users: number;
  teachers: number; institutes: number; offers_live: number; paid_30d: number; open_reports: number; top_teachers: { name: string; n: number }[];
};
type Row = {
  booking_id: string; offering_id: string; title: string; owner_name: string; student: string; parent: string | null; parent_phone: string | null;
  starts_at: string | null; status: string; pay_status: string; pay_method: string | null; price: number | null; created_at: string;
};
const STATUS: Record<string, string> = { pending: "بانتظار المعلم", confirmed: "مؤكد", cancelled: "ملغى", declined: "مرفوض", completed: "انتهى" };

/** Operations: platform numbers, find any booking by phone or name, cancel it or settle its payment. */
export async function OpsTab({ supabase, q }: { supabase: any; q: string }) {
  const [{ data: st }, found] = await Promise.all([
    supabase.rpc("admin_stats"),
    q ? supabase.rpc("admin_find_bookings", { p_q: q }) : Promise.resolve({ data: [] }),
  ]);
  const s = st as Stats | null;
  const rows = (found.data ?? []) as Row[];
  const back = `/admin?tab=ops&q=${encodeURIComponent(q)}`;
  const now = new Date().toISOString();
  return (
    <>
      {s && (
        <section className="section">
          <h2>المنصة بالأرقام</h2>
          <div className="money">
            <div className="stat hl"><b className="num">{s.bookings_7d}</b><span>حجوزات هذا الأسبوع{s.bookings_prev7d ? ` (السابق ${s.bookings_prev7d})` : ""}</span></div>
            <div className="stat"><b className="num">{s.lessons_7d}</b><span>حصص تمّت</span></div>
            <div className="stat"><b className="num">{s.new_users_7d}</b><span>حسابات جديدة</span></div>
          </div>
          <div className="money">
            <div className="stat"><b className="num">{s.teachers}</b><span>معلمون</span></div>
            <div className="stat"><b className="num">{s.institutes}</b><span>معاهد</span></div>
            <div className="stat"><b className="num">{s.offers_live}</b><span>عروض حقيقية ظاهرة</span></div>
          </div>
          <div className="money">
            <div className="stat"><b className="num">{s.users}</b><span>كل الحسابات</span></div>
            <div className="stat"><b className="num">{s.paid_30d} ₪</b><span>دُفع للمعلمين (30 يوماً)</span></div>
            <div className="stat"><b className="num">{s.cancelled_7d}</b><span>إلغاءات الأسبوع</span></div>
          </div>
          {s.top_teachers.length > 0 && (
            <p className="small">الأكثر حجزاً (30 يوماً): {s.top_teachers.map((t) => `${t.name} (${t.n})`).join("، ")}</p>
          )}
          {s.open_reports > 0 && <Link className="link small" href="/admin?tab=reports">{s.open_reports} بلاغات مفتوحة</Link>}
        </section>
      )}

      <section className="section" id="find">
        <h2>البحث في الحجوزات</h2>
        <form className="row" action="/admin" style={{ gap: 8 }}>
          <input type="hidden" name="tab" value="ops" />
          <input name="q" defaultValue={q} placeholder="رقم الهاتف، اسم الطالب أو ولي الأمر، المعلم أو المعهد" style={{ flex: 1, minWidth: 0 }} aria-label="بحث" />
          <button className="btn sm">بحث</button>
        </form>
        {q && rows.length === 0 && <div className="empty">لا حجوزات لهذا البحث.</div>}
        {rows.map((r) => (
          <div key={r.booking_id} className="card">
            <div className="row between" style={{ gap: 8 }}>
              <Link href={`/offer/${r.offering_id}`}><b>{r.title}</b></Link>
              <span className={`badge ${r.status === "confirmed" ? "ok" : r.status === "cancelled" ? "bad" : ""}`}>{STATUS[r.status] ?? r.status}</span>
            </div>
            <span className="small muted">
              {r.owner_name} · الطالب: {r.student}{r.parent && r.parent !== r.student ? ` · ولي الأمر: ${r.parent}` : ""}
              {r.parent_phone ? <> · <span className="num" dir="ltr">{r.parent_phone.replace(/^\+972/, "0")}</span></> : null}
            </span>
            <span className="small muted">
              {r.starts_at ? `${dayLong(r.starts_at)} ${time(r.starts_at)}` : "دورة / مسجّل"} · {r.price ?? 0} ₪ · الدفع: {PAY_STATUS[r.pay_status]?.label ?? r.pay_status}
            </span>
            {(r.status === "confirmed" || r.status === "pending") && (
              <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
                <details>
                  <summary className="link small">حسم الدفع</summary>
                  <form action={adminSetPaymentAction} className="formstack" style={{ marginTop: 6 }}>
                    <input type="hidden" name="booking_id" value={r.booking_id} />
                    <input type="hidden" name="back" value={back} />
                    <select name="status" defaultValue="paid" aria-label="الحالة">
                      <option value="paid">مدفوع</option>
                      <option value="unpaid">غير مدفوع</option>
                      <option value="free">مجاني (بلا دفع)</option>
                    </select>
                    <input name="reason" required placeholder="السبب، يصل للطرفين" maxLength={200} />
                    <button className="btn sm">حفظ القرار</button>
                  </form>
                </details>
                {(!r.starts_at || r.starts_at > now) && (
                  <details>
                    <summary className="link small" style={{ color: "var(--bad)" }}>إلغاء الحجز</summary>
                    <form action={adminCancelBookingAction} className="formstack" style={{ marginTop: 6 }}>
                      <input type="hidden" name="booking_id" value={r.booking_id} />
                      <input type="hidden" name="back" value={back} />
                      <input name="reason" required placeholder="السبب، يصل للطالب وللمعلم" maxLength={200} />
                      <button className="btn sm badb">تأكيد الإلغاء</button>
                    </form>
                  </details>
                )}
              </div>
            )}
          </div>
        ))}
      </section>
    </>
  );
}
