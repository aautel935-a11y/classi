import Link from "next/link";
import { Icon } from "@/components/Icon";
import {
  teacherAddBookingAction, teacherBlockAction, teacherCancelBookingAction, teacherMoveBookingAction, teacherUnblockAction,
} from "@/app/actions";
import { requireUser } from "@/lib/session";
import { dayNum, dayShort, dayLong, fromLocal, isoDay, monthName, time } from "@/lib/format";

export const dynamic = "force-dynamic";

type Item = {
  kind: "booking" | "session" | "block"; id: string; starts_at: string; minutes: number; title: string | null; who: string | null;
  status: string | null; series_id: string | null; mode: string | null; note: string | null; offering_id: string | null; changed: boolean;
};
type Student = { user_id: string; child_id: string | null; name: string; guardian: string | null };
type Row = { at: string; end: string; free?: boolean; item?: Item };

const addDays = (day: string, n: number) => {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const OK: Record<string, string> = {
  blocked: "أُغلقت الساعة. لا يستطيع الطلاب حجزها.",
  opened: "فُتحت الساعة للحجز.",
  added: "أُضيف الطالب ووصله إشعار.",
  moved: "تغيّر الموعد ووصل الطالب إشعار. يمكنه الإلغاء مجاناً إن لم يناسبه.",
  cancelled: "أُلغي الحجز ووصل الطالب إشعار بالسبب.",
};

/** The teacher's day by day: free hours, bookings, meetings and closed hours, each with its actions. */
export default async function TeacherCalendar({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase, user } = await requireUser("/teach/calendar");
  const { data: t } = await supabase.from("teachers").select("id,name,buffer_minutes").eq("user_id", user.id).maybeSingle();
  if (!t) {
    return (
      <div className="wrap"><div className="section"><h1>جدولي</h1><div className="empty">أنشئ ملف المعلم أولاً. <Link className="link" href="/teach">ملف المعلم</Link></div></div></div>
    );
  }
  const today = isoDay(new Date());
  const day = /^\d{4}-\d{2}-\d{2}$/.test(sp.day ?? "") ? sp.day! : today;
  const weekStart = addDays(day, -((new Date(`${day}T12:00:00Z`).getUTCDay() + 7) % 7)); // Sunday
  const days = Array.from({ length: 7 }, (_, i) => addDays(weekStart, i));
  const from = fromLocal(day, "00:00").toISOString();
  const to = fromLocal(addDays(day, 1), "00:00").toISOString();

  const [{ data: items }, { data: hours }, { data: offers }, { data: students }] = await Promise.all([
    supabase.rpc("my_teacher_calendar", { p_from: from, p_to: to }),
    supabase.from("availability").select("weekday,start_time,end_time").eq("teacher_id", t.id),
    supabase.from("offerings").select("id,title,minutes").eq("teacher_id", t.id).eq("type", "private").order("created_at"),
    supabase.rpc("my_students"),
  ]);
  const privateOffers = (offers ?? []) as { id: string; title: string; minutes: number | null }[];
  const lesson = privateOffers[0]?.minutes || 60;
  const step = lesson + (t.buffer_minutes ?? 0);
  const list = (items ?? []) as Item[];
  const kids = (students ?? []) as Student[];
  const wd = new Date(`${day}T12:00:00Z`).getUTCDay();
  const nowIso = new Date().toISOString();

  // Free hours from the weekly availability, minus anything that overlaps them.
  const rows: Row[] = list.map((it) => ({ at: it.starts_at, end: new Date(new Date(it.starts_at).getTime() + it.minutes * 60000).toISOString(), item: it }));
  for (const h of (hours ?? []).filter((x) => x.weekday === wd)) {
    const [sh, sm] = h.start_time.split(":").map(Number);
    const [eh, em] = h.end_time.split(":").map(Number);
    for (let m = sh * 60 + sm; m + lesson <= eh * 60 + em; m += step) {
      const hhmm = `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
      const s = fromLocal(day, hhmm).getTime();
      const e = s + lesson * 60000;
      const clash = list.some((it) => {
        const is = new Date(it.starts_at).getTime();
        return is < e && is + it.minutes * 60000 > s;
      });
      if (!clash && s > Date.now()) rows.push({ at: new Date(s).toISOString(), end: new Date(e).toISOString(), free: true });
    }
  }
  rows.sort((a, b) => a.at.localeCompare(b.at));
  const back = (extra = "") => <input type="hidden" name="day" value={day + extra} />;

  return (
    <div className="wrap">
      <div className="section">
        <Link className="back" href="/teach"><Icon name="back" />لوحتي</Link>
        <h1>جدولي وإدارة الساعات</h1>
        <p className="small muted">أغلق ساعات، أضف طلابك لساعة فارغة، أو غيّر موعد أي حصة. كل تغيير يصل للطالب فوراً.</p>
        {sp.ok && <p className="okmsg">{sp.ok.startsWith("blocked:") ? `أُغلقت الساعة لـ${sp.ok.split(":")[1]} أسابيع.` : OK[sp.ok]}{sp.ok === "added" && sp.n && Number(sp.n) > 1 ? ` (${sp.n} حصص)` : ""}{sp.skipped ? ` لم تُحجز هذه الأسابيع لأنها مشغولة: ${sp.skipped}` : ""}</p>}
        {sp.error && <p className="err">{sp.error}</p>}

        <div className="row between">
          <Link className="btn sm ghost" href={`/teach/calendar?day=${addDays(weekStart, -7)}`}>الأسبوع السابق</Link>
          {day !== today && <Link className="link small" href="/teach/calendar">اليوم</Link>}
          <Link className="btn sm ghost" href={`/teach/calendar?day=${addDays(weekStart, 7)}`}>الأسبوع التالي</Link>
        </div>
        <div className="days">
          {days.map((d) => (
            <Link key={d} className="day" aria-pressed={d === day} href={`/teach/calendar?day=${d}`}>
              {dayShort(`${d}T12:00:00Z`)}
              <b className="num">{dayNum(`${d}T12:00:00Z`)}</b>
              {monthName(`${d}T12:00:00Z`)}
            </Link>
          ))}
        </div>
        <h2>{dayLong(`${day}T12:00:00Z`)}</h2>
        {rows.length === 0 && <div className="empty">لا حصص ولا أوقات متاحة في هذا اليوم. يمكنك إضافة وقت آخر من الأسفل.</div>}

        {rows.map((r) => {
          const it = r.item;
          const past = r.at < nowIso;
          if (r.free) {
            return (
              <div key={`f${r.at}`} className="card cal-row free">
                <div className="row between"><b className="num">{time(r.at)}–{time(r.end)}</b><span className="badge">فارغ</span></div>
                <div className="row" style={{ flexWrap: "wrap", gap: 16 }}>
                  <AddStudent at={r.at} day={day} offers={privateOffers} students={kids} />
                  <CloseHour at={r.at} day={day} minutes={lesson} />
                </div>
              </div>
            );
          }
          if (!it) return null;
          if (it.kind === "block") {
            return (
              <div key={it.id} className="card cal-row blocked">
                <div className="row between"><b className="num">{time(r.at)}–{time(r.end)}</b><span className="badge bad">مغلقة</span></div>
                {it.note && <span className="small">{it.note}</span>}
                {!past && (
                  <div className="row" style={{ gap: 16 }}>
                    <form action={teacherUnblockAction}>{back()}<input type="hidden" name="id" value={it.id} /><button className="link small">فتح الساعة</button></form>
                    <form action={teacherUnblockAction}>{back()}<input type="hidden" name="id" value={it.id} /><input type="hidden" name="all" value="1" /><button className="link small">فتحها في كل الأسابيع القادمة</button></form>
                  </div>
                )}
              </div>
            );
          }
          if (it.kind === "session") {
            return (
              <Link key={it.id} className="card cal-row" href={`/manage/course/${it.offering_id}`}>
                <div className="row between"><b className="num">{time(r.at)}–{time(r.end)}</b><span className="badge">{it.status === "institute" ? "دورة معهد" : "مجموعة"}</span></div>
                <span>{it.title} · {it.who} مسجّلين</span>
                <span className="link small">{it.status === "institute" ? "الطلاب والحضور" : "تغيير موعد اللقاء والطلاب"}</span>
              </Link>
            );
          }
          return (
            <div key={it.id} className="card cal-row booked">
              <div className="row between">
                <b className="num">{time(r.at)}–{time(r.end)}</b>
                <span className={`badge ${it.status === "confirmed" ? "ok" : ""}`}>{it.status === "confirmed" ? "محجوزة" : "بانتظار ردّك"}</span>
              </div>
              <b>{it.who}</b>
              <span className="small muted">
                {it.title}{it.mode === "online" ? " · أونلاين" : it.mode === "home" ? " · حضوري" : ""}{it.series_id ? " · أسبوعي" : ""}{it.changed ? " · غيّرتَ موعدها" : ""}
              </span>
              {!past && (
                <div className="row" style={{ flexWrap: "wrap", gap: 16 }}>
                  <details>
                    <summary className="link small">تغيير الموعد</summary>
                    <form action={teacherMoveBookingAction} className="formstack" style={{ marginTop: 8 }}>
                      {back()}
                      <input type="hidden" name="id" value={it.id} />
                      <div className="typeform">
                        <label className="field">اليوم<input type="date" name="date" required defaultValue={isoDay(r.at)} min={today} /></label>
                        <label className="field">الساعة<input type="time" name="time" required defaultValue={time(r.at)} step={300} /></label>
                      </div>
                      {it.series_id && (
                        <div className="stack" style={{ gap: 4 }}>
                          <label className="row small"><input type="radio" name="scope" value="one" defaultChecked /> هذه الحصة فقط</label>
                          <label className="row small"><input type="radio" name="scope" value="following" /> هذه وكل الأسابيع بعدها</label>
                        </div>
                      )}
                      <label className="field">رسالة للطالب (اختياري)<input name="note" maxLength={200} placeholder="مثلاً: عندي امتحانات في المدرسة" /></label>
                      <button className="btn sm">حفظ الموعد الجديد</button>
                    </form>
                  </details>
                  <details>
                    <summary className="link small" style={{ color: "var(--bad)" }}>إلغاء</summary>
                    <form action={teacherCancelBookingAction} className="formstack" style={{ marginTop: 8 }}>
                      {back()}
                      <input type="hidden" name="id" value={it.id} />
                      {it.series_id && (
                        <div className="stack" style={{ gap: 4 }}>
                          <label className="row small"><input type="radio" name="scope" value="one" defaultChecked /> هذه الحصة فقط</label>
                          <label className="row small"><input type="radio" name="scope" value="series" /> إيقاف الموعد الأسبوعي كله</label>
                        </div>
                      )}
                      <label className="field">السبب (يصل للطالب)<input name="reason" maxLength={200} placeholder="مثلاً: مرض، سفر" /></label>
                      <button className="btn sm badb">تأكيد الإلغاء</button>
                    </form>
                  </details>
                </div>
              )}
            </div>
          );
        })}
      </div>

      <section className="section">
        <h2>وقت آخر</h2>
        <p className="small muted">لساعة خارج أوقاتك المعتادة: أضف طالباً أو أغلقها.</p>
        <div className="card formstack">
          <AddStudent day={day} offers={privateOffers} students={kids} custom />
          <CloseHour day={day} minutes={lesson} custom />
        </div>
        <p className="note"><Icon name="clock" />أوقاتك الأسبوعية المعتادة والاستراحة بين الحصص تُعدَّل من <Link className="link" href="/teach#hours">لوحتي</Link>.</p>
      </section>
    </div>
  );
}

function AddStudent({ at, day, offers, students, custom }: { at?: string; day: string; offers: { id: string; title: string }[]; students: Student[]; custom?: boolean }) {
  if (offers.length === 0) return custom ? <p className="small muted">أنشئ درساً خصوصياً أولاً لتضيف طلاباً.</p> : null;
  return (
    <details>
      <summary className="link small">{custom ? "إضافة طالب في وقت آخر" : "إضافة طالب"}</summary>
      {students.length === 0 ? (
        <p className="small muted" style={{ marginTop: 6 }}>تستطيع إضافة من حجز معك أو راسلك من قبل. عندما يحجز أول طالب يظهر هنا.</p>
      ) : (
        <form action={teacherAddBookingAction} className="formstack" style={{ marginTop: 8 }}>
          <input type="hidden" name="day" value={day} />
          {custom ? (
            <div className="typeform">
              <label className="field">اليوم<input type="date" name="date" required defaultValue={day} /></label>
              <label className="field">الساعة<input type="time" name="time" required defaultValue="16:00" step={300} /></label>
            </div>
          ) : (
            <>
              <input type="hidden" name="date" value={isoDay(at!)} />
              <input type="hidden" name="time" value={time(at!)} />
            </>
          )}
          <label className="field">
            الطالب
            <select name="student" required>
              {students.map((s) => (
                <option key={`${s.user_id}|${s.child_id ?? ""}`} value={`${s.user_id}|${s.child_id ?? ""}`}>{s.name}{s.guardian ? ` (ولي الأمر: ${s.guardian})` : ""}</option>
              ))}
            </select>
          </label>
          {offers.length > 1 ? (
            <label className="field">الدرس<select name="offering_id">{offers.map((o) => <option key={o.id} value={o.id}>{o.title}</option>)}</select></label>
          ) : (
            <input type="hidden" name="offering_id" value={offers[0].id} />
          )}
          <label className="row small"><input type="checkbox" name="weekly" value="1" /> نفس الموعد كل أسبوع</label>
          <button className="btn sm okb">إضافة وإبلاغ الطالب</button>
        </form>
      )}
    </details>
  );
}

function CloseHour({ at, day, minutes, custom }: { at?: string; day: string; minutes: number; custom?: boolean }) {
  return (
    <details>
      <summary className="link small">{custom ? "إغلاق ساعة أخرى" : "إغلاق الساعة"}</summary>
      <form action={teacherBlockAction} className="formstack" style={{ marginTop: 8 }}>
        <input type="hidden" name="day" value={day} />
        {custom ? (
          <div className="typeform">
            <label className="field">اليوم<input type="date" name="date" required defaultValue={day} /></label>
            <label className="field">من الساعة<input type="time" name="time" required defaultValue="16:00" step={300} /></label>
            <label className="field">المدة (دقائق)<input type="number" name="minutes" min={15} max={600} step={15} defaultValue={minutes} /></label>
          </div>
        ) : (
          <>
            <input type="hidden" name="date" value={isoDay(at!)} />
            <input type="hidden" name="time" value={time(at!)} />
            <input type="hidden" name="minutes" value={minutes} />
          </>
        )}
        <label className="field">ملاحظة لك (لا يراها الطلاب)<input name="note" maxLength={120} placeholder="مثلاً: طالب من خارج التطبيق" /></label>
        <label className="row small"><input type="checkbox" name="weekly" value="1" /> كل أسبوع (8 أسابيع)</label>
        <button className="btn sm">إغلاق</button>
      </form>
    </details>
  );
}
