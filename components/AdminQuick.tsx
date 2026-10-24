import Link from "next/link";
import { adminHideAction } from "@/app/actions";

/** Moderation bar shown to admins on public pages. */
export function AdminQuick({ kind, id, hidden, back, userId }: { kind: "teacher" | "institute" | "offering"; id: string; hidden: boolean; back: string; userId?: string | null }) {
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
    </div>
  );
}
