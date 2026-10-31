import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { writeReportAction, writeSessionReportsAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { dayLong, time } from "@/lib/format";
import { LEVELS } from "@/lib/types";
import { ErrorNote } from "@/components/ErrorNote";
import { safePath } from "@/lib/safe";

export const dynamic = "force-dynamic";

const uuid = (s?: string) => (s && /^[0-9a-f-]{36}$/i.test(s) ? s : null);

function Rating({ name, label, value }: { name: string; label: string; value?: number | null }) {
  return (
    <fieldset className="rating">
      <legend className="small">{label}</legend>
      <div className="rating-opts">
        {[1, 2, 3, 4, 5].map((n) => (
          <label key={n}>
            <input type="radio" name={name} value={n} defaultChecked={value === n} />
            <span>{LEVELS[n]}</span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

/** The teacher writes the report for one lesson, or for every student of a group/course meeting. */
export default async function ReportPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const booking = uuid(sp.booking);
  const session = uuid(sp.session);
  if (!booking && !session) notFound();
  const { supabase } = await requireUser(`/teach/report?${booking ? `booking=${booking}` : `session=${session}`}`);
  const back = safePath(sp.back, "/teach");

  if (booking) {
    const [{ data: b }, { data: r }] = await Promise.all([
      supabase.from("bookings").select("id,starts_at,offering_id,offering:offerings(title,type),session:sessions(starts_at)").eq("id", booking).maybeSingle(),
      supabase.from("lesson_reports").select("present,summary,homework,understanding,participation,note").eq("booking_id", booking).is("session_id", null).maybeSingle(),
    ]);
    if (!b) notFound();
    const x = b as any;
    const { data: roster } = await supabase.rpc("owner_bookings", { p_offering: x.offering_id });
    const who = ((roster ?? []) as { booking_id: string; student_name: string }[]).find((y) => y.booking_id === booking)?.student_name ?? "الطالب";
    const at = x.starts_at ?? x.session?.starts_at;
    return (
      <div className="wrap">
        <form action={writeReportAction} className="section formstack">
          <Link className="back" href={back}><Icon name="back" />رجوع</Link>
          <h1>تقرير الحصة</h1>
          <p className="muted">{x.offering?.title} · <b>{who}</b>{at ? ` · ${dayLong(at)} ${time(at)}` : ""}</p>
          <ErrorNote msg={sp.error} />
          {r && <p className="note"><Icon name="check" />كتبت تقريراً لهذه الحصة. التعديل يرسل إشعاراً جديداً لولي الأمر.</p>}
          <input type="hidden" name="booking_id" value={booking} />
          <input type="hidden" name="back" value={back} />
          <label className="row small"><input type="checkbox" name="absent" defaultChecked={r ? !r.present : false} /> الطالب لم يحضر</label>
          <label className="field">ماذا تعلّمنا اليوم؟<textarea name="summary" rows={3} maxLength={2000} defaultValue={r?.summary ?? ""} placeholder="مثلاً: راجعنا المعادلات التربيعية وحللنا 8 تمارين" /></label>
          <label className="field">الواجب للحصة القادمة<textarea name="homework" rows={2} maxLength={1000} defaultValue={r?.homework ?? ""} placeholder="مثلاً: تمارين 1-10 صفحة 45" /></label>
          <Rating name="understanding" label="مستوى الفهم" value={r?.understanding} />
          <Rating name="participation" label="المشاركة والتركيز" value={r?.participation} />
          <label className="field">ملاحظة لولي الأمر<textarea name="note" rows={2} maxLength={1000} defaultValue={r?.note ?? ""} placeholder="مثلاً: تقدّم ممتاز، يحتاج انتباهاً أكثر للإشارات" /></label>
          <p className="small muted"><Icon name="bell" /> يصل ولي الأمر إشعار فوري بالتقرير.</p>
          <button className="btn block">{r ? "تحديث التقرير" : "إرسال التقرير لولي الأمر"}</button>
        </form>
      </div>
    );
  }

  const [{ data: s }, { data: students }] = await Promise.all([
    supabase.from("sessions").select("id,starts_at,seq,offering:offerings(title,type)").eq("id", session!).maybeSingle(),
    supabase.rpc("session_students", { p_session: session }),
  ]);
  if (!s) notFound();
  const x = s as any;
  const list = (students ?? []) as { booking_id: string; who: string; report_id: string | null; present: boolean; understanding: number | null; participation: number | null; note: string | null; summary: string | null; homework: string | null }[];
  const shared = list.find((l) => l.summary);
  return (
    <div className="wrap">
      <form action={writeSessionReportsAction} className="section formstack">
        <Link className="back" href={back}><Icon name="back" />رجوع</Link>
        <h1>تقرير اللقاء</h1>
        <p className="muted">{x.offering?.title} · اللقاء {x.seq} · {dayLong(x.starts_at)} {time(x.starts_at)}</p>
        <ErrorNote msg={sp.error} />
        {list.length === 0 && <div className="empty">لا طلاب مؤكدون في هذا اللقاء.</div>}
        <input type="hidden" name="session_id" value={session!} />
        <input type="hidden" name="back" value={back} />
        <input type="hidden" name="count" value={list.length} />
        <label className="field">ماذا تعلّمنا في اللقاء؟ (يصل لكل الطلاب)<textarea name="summary" rows={3} required maxLength={2000} defaultValue={shared?.summary ?? ""} /></label>
        <label className="field">الواجب<textarea name="homework" rows={2} maxLength={1000} defaultValue={shared?.homework ?? ""} /></label>
        <h2>الطلاب</h2>
        {list.map((l, i) => (
          <div key={l.booking_id} className="card formstack">
            <input type="hidden" name={`b_${i}`} value={l.booking_id} />
            <div className="row between">
              <b>{l.who}</b>
              <label className="row small"><input type="checkbox" name={`absent_${i}`} defaultChecked={!l.present} /> لم يحضر</label>
            </div>
            <div className="typeform">
              <label className="field">الفهم
                <select name={`u_${i}`} defaultValue={l.understanding ?? ""}><option value="">—</option>{[1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{LEVELS[n]}</option>)}</select>
              </label>
              <label className="field">المشاركة
                <select name={`p_${i}`} defaultValue={l.participation ?? ""}><option value="">—</option>{[1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{LEVELS[n]}</option>)}</select>
              </label>
            </div>
            <input className="inline-input" name={`n_${i}`} maxLength={1000} defaultValue={l.note ?? ""} placeholder="ملاحظة خاصة لولي أمر هذا الطالب (اختياري)" />
          </div>
        ))}
        {list.length > 0 && <button className="btn block">إرسال التقارير ({list.length})</button>}
      </form>
    </div>
  );
}
