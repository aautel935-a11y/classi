import { confirmPaymentAction, reportPaymentAction } from "@/app/actions";
import { BitCopy } from "@/components/BitCopy";

export const PAY_STATUS: Record<string, { label: string; tone: string }> = {
  unpaid: { label: "لم يُدفع", tone: "" },
  reported: { label: "بانتظار تأكيد المعلم", tone: "" },
  paid: { label: "مدفوعة", tone: "ok" },
  free: { label: "مجانية", tone: "ok" },
  package: { label: "ضمن الرزمة", tone: "ok" },
};

export function PayBadge({ status, method, teacherView = false }: { status: string; method?: string | null; teacherView?: boolean }) {
  let label = PAY_STATUS[status]?.label ?? status;
  if (status === "unpaid") label = method === "cash" ? (teacherView ? "نقداً، لم تستلم بعد" : "الدفع نقداً عند الحصة") : teacherView ? "Bit، لم يصل بعد" : "حوّل عبر Bit";
  if (status === "reported" && teacherView) label = "حوّل عبر Bit، أكّد الاستلام";
  return <span className={`badge ${PAY_STATUS[status]?.tone ?? ""} ${status === "reported" ? "warn" : ""}`}>{label}</span>;
}

/** Student side: the teacher's Bit number and "I transferred". */
export function PayForStudent({ bookingId, packageId, status, method, amount, bit, owner, back }: {
  bookingId?: string; packageId?: string; status: string; method?: string | null; amount?: number | null; bit?: string | null; owner?: string | null; back: string;
}) {
  if (status !== "unpaid" || method === "cash") return null;
  return (
    <div className="paybox">
      {bit ? (
        <>
          <span className="small">حوّل <b className="num">{amount ?? ""} ₪</b> عبر Bit إلى {owner ?? "المعلم"}:</span>
          <BitCopy phone={bit} />
        </>
      ) : (
        <span className="small muted">لم يضف {owner ?? "المعلم"} رقم Bit بعد. راسله لترتيب الدفع، أو ادفع نقداً.</span>
      )}
      <form action={reportPaymentAction}>
        {bookingId && <input type="hidden" name="booking_id" value={bookingId} />}
        {packageId && <input type="hidden" name="package_id" value={packageId} />}
        <input type="hidden" name="back" value={back} />
        <button className="btn sm okb">حوّلت المبلغ</button>
      </form>
    </div>
  );
}

/** Teacher side: mark money as received (or a reported transfer as not arrived). */
export function ConfirmPay({ bookingId, packageId, status, back }: { bookingId?: string; packageId?: string; status: string; back: string }) {
  if (status !== "unpaid" && status !== "reported") return null;
  const hidden = (
    <>
      {bookingId && <input type="hidden" name="booking_id" value={bookingId} />}
      {packageId && <input type="hidden" name="package_id" value={packageId} />}
      <input type="hidden" name="back" value={back} />
    </>
  );
  return (
    <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
      <form action={confirmPaymentAction}>{hidden}<button className="btn sm okb">استلمت المبلغ</button></form>
      {status === "reported" && (
        <form action={confirmPaymentAction}>{hidden}<input type="hidden" name="received" value="0" /><button className="link small" style={{ color: "var(--bad)" }}>لم يصل</button></form>
      )}
    </div>
  );
}
