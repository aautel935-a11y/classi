import Link from "next/link";
import { Icon } from "@/components/Icon";
import { setEmailRemindersAction } from "@/app/actions";
import { PushToggle } from "@/components/PushToggle";
import { requireUser } from "@/lib/session";
import { dayLong, time } from "@/lib/format";

export const dynamic = "force-dynamic";

const ICON: Record<string, "cal" | "check" | "bell" | "users" | "chat" | "monitor" | "shield" | "clock"> = {
  reminder: "clock", reminder_soon: "clock", lesson_report: "check", report_due: "clock", payment_reported: "check", payment_answer: "check", review_needed: "shield", review_answer: "shield",
  schedule_changed: "cal", booking_answer: "check", booking_request: "users", booking_new: "users", booking_cancelled: "bell", waitlist_join: "users", waitlist_open: "check", waitlist_answer: "chat",
  message: "chat", link: "monitor", verify: "shield", report: "shield", reminder_today: "clock", admin_note: "bell", review_new: "check", review_prompt: "check",
  staff_invite: "users", staff_answer: "users", staff_removed: "users", booking_withdrawn: "bell", link_request: "users", link_answer: "users",
};

export default async function Notifications() {
  const { supabase, profile } = await requireUser("/notifications");
  const emailOn = profile?.email_reminders !== false;
  const { data } = await supabase.from("notifications").select("id,kind,body,link,read_at,created_at").order("created_at", { ascending: false }).limit(60);
  const list = data ?? [];
  const unreadIds = list.filter((n) => !n.read_at).map((n) => n.id);
  const unread = unreadIds.length > 0;
  // Opening the list counts as reading it (BUG-14): the bell badge clears; this visit still highlights what was new.
  if (unread) await supabase.from("notifications").update({ read_at: new Date().toISOString() }).in("id", unreadIds);
  return (
    <div className="wrap">
      <div className="section">
        <div className="row between">
          <h1>الإشعارات</h1>
          {unread && <span className="small muted">{unreadIds.length} جديد</span>}
        </div>
        <PushToggle />
        <form action={setEmailRemindersAction} className="row between small">
          <span className="muted">تذكير بالبريد قبل الحصة بيوم: {emailOn ? "مفعّل" : "متوقف"}</span>
          <input type="hidden" name="on" value={emailOn ? "0" : "1"} />
          <button className="link small">{emailOn ? "إيقاف" : "تفعيل"}</button>
        </form>
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
