import Link from "next/link";
import { adminHideAction, adminEditOfferAction } from "@/app/actions";

/** Moderation bar shown to admins on public pages. */
export function AdminQuick({ kind, id, hidden, back, userId, title }: { kind: "teacher" | "institute" | "offering"; id: string; hidden: boolean; back: string; userId?: string | null; title?: string }) {
  return (
    <div className="admin-quick">
      <span className="small"><b>الإدارة</b>{hidden ? " · مخفي عن الطلاب" : ""}</span>
      <form action={adminHideAction}>
        <input type="hidden" name="kind" value={kind} />
        <input type="hidden" name="id" value={id} />
        <input type="hidden" name="hidden" value={hidden ? "0" : "1"} />
        <input type="hidden" name="back" value={back} />
        <button className={`btn sm ${hidden ? "okb" : "badb"}`}>{hidden ? "إظهار" : "إخفاء عن الطلاب"}</button>
      </form>
      {userId && <Link className="btn sm ghost" href={`/admin/users/${userId}`}>الحساب والإيقاف</Link>}
      {kind === "offering" && title && (
        <details style={{ width: "100%" }}>
          <summary className="link small">تعديل العنوان</summary>
          <form action={adminEditOfferAction} className="formstack" style={{ marginTop: 6 }}>
            <input type="hidden" name="id" value={id} />
            <input type="hidden" name="back" value={back} />
            <input name="title" defaultValue={title} required minLength={3} maxLength={120} aria-label="العنوان" />
            <input name="reason" placeholder="ملاحظة للمعلم (اختياري)، مثلاً: حذفنا رقم الهاتف" maxLength={150} />
            <button className="btn sm">حفظ، يصل المعلم إشعار</button>
          </form>
        </details>
      )}
    </div>
  );
}
