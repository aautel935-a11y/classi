import { Icon } from "@/components/Icon";
import { ConfirmPay, PayBadge } from "@/components/Pay";
import { dayLong, shekel } from "@/lib/format";

export type PayRow = { kind: "booking" | "package"; id: string; offering_id: string; title: string; who: string; amount: number; pay_method: string; pay_status: string; lesson_at: string; reported_at: string | null; installments_total?: number; installments_paid?: number };
export type MoneySummary = { paid_month: number; open_amount: number; reported: number };

/** Teacher/institute: money to confirm (Bit transfers reported) and to collect (cash, unpaid). */
export function PaymentsOwner({ rows, summary, back, hasBit, flash }: { rows: PayRow[]; summary: MoneySummary | null; back: string; hasBit: boolean; flash?: string }) {
  const reported = rows.filter((r) => r.pay_status === "reported");
  const open = rows.filter((r) => r.pay_status === "unpaid");
  return (
    <section className="section" id="payments">
      <h2>الدفعات</h2>
      {flash === "payment" && <p className="okmsg">حُدّثت حالة الدفع.</p>}
      {!hasBit && <p className="note"><Icon name="shield" />أضف رقم Bit في ملفك ليتمكن الطلاب من التحويل لك مباشرة.</p>}
      {summary && (
        <div className="money">
          <div className="stat hl"><b className="num">{shekel(summary.paid_month)}</b><span>وصلك هذا الشهر</span></div>
          <div className="stat"><b className="num">{shekel(summary.open_amount)}</b><span>لم يُدفع بعد</span></div>
          <div className="stat"><b className="num">{summary.reported}</b><span>تحويلات للتأكيد</span></div>
        </div>
      )}
      {rows.length === 0 && <div className="empty">لا دفعات مفتوحة. كل الحصص التي مضت مدفوعة.</div>}
      {[...reported, ...open].map((r) => (
        <div key={`${r.kind}${r.id}`} className="card">
          <div className="row between">
            <b>{r.who}</b>
            <b className="num">{shekel(r.amount)}</b>
          </div>
          <span className="small muted">{r.title} · {dayLong(r.lesson_at)}</span>
          <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
            <PayBadge status={r.pay_status} method={r.pay_method} teacherView inst={(r.installments_total ?? 1) > 1 ? [r.installments_paid ?? 0, r.installments_total!] : undefined} />
            <ConfirmPay bookingId={r.kind === "booking" ? r.id : undefined} packageId={r.kind === "package" ? r.id : undefined} status={r.pay_status} back={back} installment={(r.installments_total ?? 1) > 1 ? [(r.installments_paid ?? 0) + 1, r.installments_total!] : undefined} />
          </div>
        </div>
      ))}
    </section>
  );
}
