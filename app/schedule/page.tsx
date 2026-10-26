import Link from "next/link";
import { Icon } from "@/components/Icon";
import { cancelBookingAction, cancelSeriesAction, leaveWaitlistAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { PushToggle } from "@/components/PushToggle";
import { PayBadge, PayForStudent, installmentAmount } from "@/components/Pay";
import { PAY_LABEL, PLACES, type Place } from "@/lib/types";
import { dayLong, dayNum, dayShort, monthName, time } from "@/lib/format";
import { googleCalLink } from "@/lib/contact";
import { WhatsAppButton } from "@/components/WhatsAppButton";

export const dynamic = "force-dynamic";

type Row = {
  id: string; status: string; pay_method: string; starts_at: string | null; session_id: string | null; mode: Place | null; price: number | null; series_id: string | null; pay_status: string; installments_total: number; installments_paid: number;
  child: { name: string } | null;
  session: { starts_at: string } | null;
  offering: { id: string; type: string; title: string; minutes: number; places: Place[]; teacher: { name: string; whatsapp: string | null } | null; institute: { name: string; whatsapp: string | null } | null };
};

export default async function Schedule({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase, user, profile } = await requireUser("/schedule");
  const { data } = await supabase
    .from("bookings")
    .select("id,status,pay_method,starts_at,session_id,mode,price,series_id,pay_status,installments_total,installments_paid,child:children(name),session:sessions(starts_at),offering:offerings(id,type,title,minutes,places,teacher:teachers!offerings_teacher_id_fkey(name,whatsapp),institute:institutes(name,whatsapp))")
    .eq("booked_by", user.id)
    .in("status", ["pending", "confirmed"])
    .order("created_at", { ascending: false });
  const rows = ((data ?? []) as unknown as Row[]).filter((r) => r.offering);
  const [{ data: links }, { data: wl }, { count: unreadReports0 }, { data: payNums }] = await Promise.all([
    supabase.from("offering_links").select("offering_id,url,note"),
    supabase.rpc("my_waitlist"),
    supabase.from("lesson_reports").select("id", { count: "exact", head: true }).eq("student_user", user.id).is("read_at", null),
    supabase.rpc("my_pay_numbers"),
  ]);
  const payOf = (oid: string) => ((payNums ?? []) as { offering_id: string; owner_name: string; bit_phone: string | null }[]).find((p) => p.offering_id === oid);
  const unreadReports = unreadReports0 ?? 0;
  const waits = (wl ?? []) as { id: string; offering_id: string; offering_title: string; owner_name: string; child_name: string | null; status: string; reply: string | null; pos: number | null }[];
  const linkOf = (oid: string) => (links ?? []).find((l) => l.offering_id === oid);

  // courses: show the next meeting and whether the institute changed times
  const courseIds = rows.filter((r) => r.offering.type === "course").map((r) => r.offering.id);
  const { data: cs } = courseIds.length
    ? await supabase.from("sessions").select("offering_id,starts_at,changed,room:rooms(name)").in("offering_id", courseIds).eq("cancelled", false).gt("starts_at", new Date().toISOString()).order("starts_at")
    : { data: [] as any[] };
  const nextOf = (oid: string) => (cs ?? []).find((s: any) => s.offering_id === oid) as any;
  const changedOf = (oid: string) => (cs ?? []).some((s: any) => s.offering_id === oid && s.changed);

  const items = rows
    .map((r) => {
      const n = r.offering.type === "course" ? nextOf(r.offering.id) : null;
      const at = r.starts_at ?? r.session?.starts_at ?? n?.starts_at ?? null;
      return { r, at, room: n?.room?.name as string | undefined, changed: r.offering.type === "course" && changedOf(r.offering.id) };
    })
    .sort((a, b) => (a.at ?? "9").localeCompare(b.at ?? "9"));
  // A weekly series shows once: its next lesson, with how many are booked ahead.
  const now = new Date().toISOString();
  const seriesCount = new Map<string, number>();
  items.forEach(({ r, at }) => { if (r.series_id && (!at || at > now)) seriesCount.set(r.series_id, (seriesCount.get(r.series_id) ?? 0) + 1); });
  const shown = new Set<string>();
  const visible = items.filter(({ r, at }) => {
    if (!r.series_id) return true;
    if (at && at < now) return false;
    if (shown.has(r.series_id)) return false;
    shown.add(r.series_id);
    return true;
  });

  return (
    <div className="wrap">
      <div className="section">
        <h1>جدولي</h1>
        {sp.booked && (
          <div className="okmsg">
            {sp.booked === "weekly"
              ? `${sp.instant === "1" ? "تم تثبيت موعدك الأسبوعي" : "أُرسل طلبك الأسبوعي للمعلم"}: ${sp.created ?? ""} حصص محجوزة للأسابيع القادمة.`
              : sp.instant === "0" ? "أُرسل طلب الحجز للمعلم. يصلك إشعار عند موافقته." : "تم الحجز. تجد التفاصيل هنا وفي الإشعارات."}
            {sp.skipped && <p className="small" style={{ marginTop: 4 }}>لم نحجز هذه المواعيد لأن المعلم مشغول فيها: {sp.skipped}</p>}
          </div>
        )}
        {sp.cancelled_series && <p className="okmsg">أُلغي الموعد الأسبوعي ({sp.cancelled_series} حصص قادمة).</p>}
        {sp.error && <p className="err">{sp.error}</p>}
        <div className="row between">
          <p className="small muted">كل الحصص والدورات لك ولأبنائك في مكان واحد.</p>
          <Link className="btn sm ghost" href="/reports"><Icon name="check" />تقارير الحصص{unreadReports > 0 ? ` (${unreadReports})` : ""}</Link>
        </div>
        {sp.left && <p className="okmsg">خرجت من قائمة الانتظار.</p>}
        {sp.paid_reported && <p className="okmsg">أبلغنا المعلم بالتحويل. تصلك رسالة عندما يؤكد الاستلام.</p>}
        <PushToggle compact />
        {waits.length > 0 && (
          <div className="stack" style={{ gap: 8 }}>
            <h2>قوائم الانتظار</h2>
            {waits.map((w) => (
              <div key={w.id} className="card">
                <div className="row between">
                  <Link href={`/offer/${w.offering_id}`}><b>{w.offering_title}</b></Link>
                  <span className={`badge ${w.status === "notified" ? "ok" : w.status === "declined" ? "bad" : ""}`}>
                    {w.status === "notified" ? "تحرّر مكان" : w.status === "accepted" ? "ردّ المعلم" : w.status === "declined" ? "اعتذار" : `رقم ${w.pos}`}
                  </span>
                </div>
                <span className="small muted">{w.owner_name} · {w.child_name ?? "أنا"}</span>
                {w.status === "notified" && <Link className="btn sm" href={`/offer/${w.offering_id}`}>احجز الآن</Link>}
                {w.status === "accepted" && <Link className="link small" href="/messages">تابع في الرسائل</Link>}
                {w.reply && <span className="small">«{w.reply}»</span>}
                {(w.status === "waiting" || w.status === "notified") && (
                  <form action={leaveWaitlistAction}>
                    <input type="hidden" name="id" value={w.id} />
                    <input type="hidden" name="back" value="/schedule" />
                    <button className="link small" style={{ color: "var(--bad)" }}>الخروج من القائمة</button>
                  </form>
                )}
              </div>
            ))}
          </div>
        )}
        {visible.length === 0 && (
          <div className="empty">
            لا حصص بعد. <Link className="link" href="/search">ابحث عن معلم</Link> واحجز أول حصة.
          </div>
        )}
        {visible.map(({ r, at, room, changed }) => (
          <div key={r.id} className="card lesson">
            <div className="date">
              {at ? (
                <>
                  <span>{dayShort(at)}</span>
                  <b className="num">{dayNum(at)}</b>
                  <span>{monthName(at)}</span>
                </>
              ) : (
                <Icon name="play" />
              )}
            </div>
            <div className="lesson-body">
              <b>{r.offering.title}</b>
              <span className="small muted">{r.offering.teacher ? `أ. ${r.offering.teacher.name}` : r.offering.institute?.name}</span>
              <div className="meta">
                {at && (
                  <span>
                    <Icon name="clock" />
                    <span className="num">{time(at)}</span>
                  </span>
                )}
                <span>
                  <Icon name="person" />
                  {r.child?.name ?? "أنا"}
                </span>
                {r.offering.type !== "recorded" && (
                  <span>
                    <Icon name={(r.mode ?? r.offering.places[0]) === "online" ? "monitor" : "pin"} />
                    {room ?? (r.mode ? (r.mode === "online" ? "أونلاين" : PLACES[r.mode]) : r.offering.places.map((p) => PLACES[p]).join(" أو "))}
                  </span>
                )}
              </div>
              <div className="row" style={{ flexWrap: "wrap" }}>
                {r.status === "confirmed" ? (
                  <span className="badge ok"><Icon name="check" />مؤكد</span>
                ) : (
                  <span className="badge">بانتظار موافقة المعلم</span>
                )}
                {changed && <span className="badge">غيّر المعهد الموعد</span>}
                {r.series_id && <span className="badge"><Icon name="cal" />أسبوعي · {seriesCount.get(r.series_id) ?? 0} حصص قادمة</span>}
                <PayBadge status={r.pay_status} method={r.pay_method} inst={r.installments_total > 1 ? [r.installments_paid, r.installments_total] : undefined} />
                {r.price != null && r.price > 0 && <span className="badge num">{r.price} ₪</span>}
              </div>
              {r.status === "confirmed" && at && at < now && r.offering.type !== "recorded" && (
                <Link className="link small" href={`/review?booking=${r.id}`}>★ قيّم {r.offering.teacher ? `أ. ${r.offering.teacher.name}` : r.offering.institute?.name}</Link>
              )}
              {at && at > now && r.offering.type !== "recorded" && (() => {
                const who = r.offering.teacher ? `أ. ${r.offering.teacher.name}` : r.offering.institute?.name ?? "";
                const wa = r.offering.teacher?.whatsapp ?? r.offering.institute?.whatsapp ?? null;
                const student = r.child?.name ?? profile?.full_name ?? "";
                const msg = `مرحباً ${who}، ${r.status === "confirmed" ? "حجزت" : "طلبت حجز"} «${r.offering.title}» يوم ${dayLong(at)} الساعة ${time(at)}${student ? ` باسم ${student}` : ""} عبر Classi.`;
                return (
                  <div className="row" style={{ gap: 12, flexWrap: "wrap", alignItems: "center" }}>
                    <details>
                      <summary className="link small"><Icon name="cal" /> أضف إلى التقويم</summary>
                      <div className="row" style={{ gap: 8, marginTop: 6, flexWrap: "wrap" }}>
                        <a className="btn sm ghost" href={googleCalLink(`${r.offering.title} · ${who}`, at, r.offering.minutes || 60, "حجز عبر Classi\nhttps://classi-nine.vercel.app/schedule")} target="_blank" rel="noopener noreferrer">Google</a>
                        <a className="btn sm ghost" href={`/api/ics/${r.id}`}>iPhone / Outlook</a>
                      </div>
                      {(r.series_id || r.offering.type === "course") && <span className="small muted">ملف iPhone / Outlook يضيف كل المواعيد القادمة دفعة واحدة.</span>}
                    </details>
                    <WhatsAppButton phone={wa} text={msg} label="أرسل التفاصيل على واتساب" small />
                  </div>
                );
              })()}
              {r.status === "confirmed" && (
                <PayForStudent bookingId={r.id} status={r.pay_status} method={r.pay_method} amount={r.price != null ? installmentAmount(r.price, r.installments_total, r.installments_paid) : null} bit={payOf(r.offering.id)?.bit_phone} owner={payOf(r.offering.id)?.owner_name} back="/schedule" />
              )}
              {(() => {
                const l = linkOf(r.offering.id);
                const wantsLink = r.offering.type === "recorded" || (r.mode ?? r.offering.places[0]) === "online" || (r.offering.type !== "private" && r.offering.places.includes("online"));
                if (!wantsLink || r.status !== "confirmed") return null;
                return l ? (
                  <div className="stack" style={{ gap: 4 }}>
                    <a className="btn sm" href={l.url} target="_blank" rel="noopener noreferrer">
                      <Icon name={r.offering.type === "recorded" ? "play" : "monitor"} />
                      {r.offering.type === "recorded" ? "شاهد المحتوى" : "ادخل إلى اللقاء أونلاين"}
                    </a>
                    {l.note && <span className="small muted">{l.note}</span>}
                  </div>
                ) : (
                  <span className="small muted">الرابط لم يُضف بعد. يصلك إشعار عندما يضيفه المعلم.</span>
                );
              })()}
              {r.offering.type !== "recorded" && (
                <div className="row" style={{ gap: 16, flexWrap: "wrap" }}>
                  <form action={cancelBookingAction} className="inline-form">
                    <input type="hidden" name="id" value={r.id} />
                    <button className="link small" style={{ color: "var(--bad)" }}>{r.series_id ? "إلغاء هذه الحصة فقط" : "إلغاء الحجز"}</button>
                  </form>
                  {r.series_id && (
                    <details>
                      <summary className="link small" style={{ color: "var(--bad)" }}>إيقاف الموعد الأسبوعي</summary>
                      <form action={cancelSeriesAction} className="row" style={{ marginTop: 6, flexWrap: "wrap" }}>
                        <input type="hidden" name="id" value={r.series_id} />
                        <span className="small">تُلغى كل الحصص القادمة.</span>
                        <button className="btn sm badb">تأكيد الإيقاف</button>
                      </form>
                    </details>
                  )}
                </div>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
