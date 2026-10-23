import Link from "next/link";
import { Icon } from "@/components/Icon";
import { markAllReadAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { dayLong, time } from "@/lib/format";

export const dynamic = "force-dynamic";

const ICON: Record<string, "cal" | "check" | "bell" | "users"> = {
  schedule_changed: "cal", booking_answer: "check", booking_request: "users", booking_new: "users", booking_cancelled: "bell",
};

export default async function Notifications() {
  const { supabase } = await requireUser("/notifications");
  const { data } = await supabase.from("notifications").select("id,kind,body,link,read_at,created_at").order("created_at", { ascending: false }).limit(60);
  const list = data ?? [];
  const unread = list.some((n) => !n.read_at);
  return (
    <div className="wrap">
      <div className="section">
        <div className="row between">
          <h1>الإشعارات</h1>
          {unread && (
            <form action={markAllReadAction}>
              <button className="link small">تعليم الكل كمقروء</button>
            </form>
          )}
        </div>
        {list.length === 0 && <div className="empty">لا إشعارات بعد. أي حجز أو تغيير في المواعيد يظهر هنا.</div>}
        {list.map((n) => (
          <Link key={n.id} href={n.link ?? "#"} className={`card notice ${n.read_at ? "" : "unread"}`}>
            <span className="ico"><Icon name={ICON[n.kind] ?? "bell"} /></span>
            <div className="stack" style={{ gap: 2, minWidth: 0 }}>
              <p>{n.body}</p>
              <span className="small muted">{dayLong(n.created_at)} · {time(n.created_at)}</span>
            </div>
          </Link>
        ))}
      </div>
    </div>
  );
}
