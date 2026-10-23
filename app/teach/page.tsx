import Link from "next/link";
import { Icon } from "@/components/Icon";
import { OfferCard } from "@/components/OfferCard";
import { respondAction, teacherSetupAction, toggleOfferingAction, updateTeacherAction } from "@/app/actions";
import { PhotoUpload } from "@/components/PhotoUpload";
import { requireUser } from "@/lib/session";
import { OFFERING_SELECT, TOWNS, type Offering } from "@/lib/types";
import { dayLong, isoDay, time } from "@/lib/format";

export const dynamic = "force-dynamic";

type BRow = { booking_id: string; offering_title: string; offering_type: string; student_name: string; starts_at: string | null; status: string; pay_method: string };

export default async function Teach({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase, user, profile } = await requireUser("/teach");
  const { data: t } = await supabase.from("teachers").select("id,name,verify,town,bio,years,is_school_teacher,subject_id,photo_url").eq("user_id", user.id).maybeSingle();

  if (!t) {
    const { data: subjects } = await supabase.from("subjects").select("id,name").order("id");
    return (
      <div className="wrap">
        <form action={teacherSetupAction} className="section">
          <h1>ملف المعلم</h1>
          <p className="muted">يظهر ملفك للطلاب بعد أن نراجع هويتك وشهاداتك.</p>
          {sp.error && <p className="err">{sp.error}</p>}
          <label className="field" htmlFor="name">الاسم كما يظهر للطلاب<input id="name" name="name" required defaultValue={profile?.full_name ?? ""} /></label>
          <div className="typeform">
            <label className="field" htmlFor="town">البلد<select id="town" name="town" defaultValue={profile?.town ?? "باقة الغربية"}>{TOWNS.map((x) => <option key={x}>{x}</option>)}</select></label>
            <label className="field" htmlFor="subject_id">المادة الرئيسية<select id="subject_id" name="subject_id">{(subjects ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
            <label className="field" htmlFor="years">سنوات الخبرة<input id="years" name="years" type="number" min={0} defaultValue={1} /></label>
          </div>
          <label className="row"><input type="checkbox" name="school" /> أنا معلم في مدرسة</label>
          <label className="field" htmlFor="bio">عن أسلوبك في التدريس<textarea id="bio" name="bio" rows={4} placeholder="ماذا تدرّس، لمن، وكيف تشرح" /></label>
          <button className="btn block">حفظ الملف</button>
        </form>
      </div>
    );
  }

  const [{ data: bookings }, { data: offers }, { data: courseSessions }, { data: subjectList }] = await Promise.all([
    supabase.rpc("owner_bookings"),
    supabase.from("offerings").select(OFFERING_SELECT).eq("teacher_id", t.id).order("created_at"),
    supabase
      .from("sessions")
      .select("id,seq,starts_at,changed,room:rooms(name),offering:offerings!inner(title,course_teacher_id,institute:institutes(name))")
      .eq("offering.course_teacher_id", t.id)
      .gt("starts_at", new Date().toISOString())
      .order("starts_at")
      .limit(6),
    supabase.from("subjects").select("id,name").order("id"),
  ]);
  const rows = (bookings ?? []) as BRow[];
  const requests = rows.filter((b) => b.status === "pending");
  const today = isoDay(new Date());
  const todays = rows.filter((b) => b.status === "confirmed" && b.starts_at && isoDay(b.starts_at) === today);
  const upcoming = rows.filter((b) => b.status === "confirmed" && b.starts_at && b.starts_at > new Date().toISOString()).slice(0, 6);
  const mine = (offers ?? []) as unknown as Offering[];

  return (
    <div className="wrap">
      <div className="section">
        <h1>لوحتي، أ. {t.name.split(" ")[0]}</h1>
        {t.verify !== "verified" && (
          <p className="note"><Icon name="shield" />ملفك بانتظار التوثيق. عروضك تظهر للطلاب بعد التوثيق.</p>
        )}
        {sp.ok && <p className="okmsg">{sp.ok === "profile" ? "حُفظ ملفك." : "نُشر العرض."}</p>}
        {sp.error && <p className="err">{sp.error}</p>}
        <div className="stats">
          <div className="stat hl"><b className="num">{todays.length}</b><span>حصص اليوم</span></div>
          <div className="stat"><b className="num">{requests.length}</b><span>طلبات جديدة</span></div>
          <div className="stat"><b className="num">{new Set(rows.filter((b) => b.status === "confirmed").map((b) => b.student_name)).size}</b><span>طلاب</span></div>
        </div>
      </div>

      <section className="section">
        <h2>ملفي</h2>
        <div className="card">
          <PhotoUpload kind="teacher" name={t.name} current={t.photo_url} />
          <details>
            <summary className="link small">تعديل البيانات والنبذة</summary>
            <form action={updateTeacherAction} className="formstack" style={{ marginTop: 12 }}>
              <label className="field" htmlFor="e-name">الاسم<input id="e-name" name="name" required defaultValue={t.name} /></label>
              <div className="typeform">
                <label className="field" htmlFor="e-town">البلد<select id="e-town" name="town" defaultValue={t.town}>{TOWNS.map((x) => <option key={x}>{x}</option>)}</select></label>
                <label className="field" htmlFor="e-subject">المادة<select id="e-subject" name="subject_id" defaultValue={t.subject_id ?? ""}>{(subjectList ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
                <label className="field" htmlFor="e-years">سنوات الخبرة<input id="e-years" name="years" type="number" min={0} defaultValue={t.years} /></label>
              </div>
              <label className="row"><input type="checkbox" name="school" defaultChecked={t.is_school_teacher} /> أنا معلم في مدرسة</label>
              <label className="field" htmlFor="e-bio">عن أسلوبك في التدريس<textarea id="e-bio" name="bio" rows={4} defaultValue={t.bio} /></label>
              <button className="btn">حفظ</button>
            </form>
          </details>
          <Link className="link small" href={`/teacher/${t.id}`}>كيف يرى الطلاب ملفي</Link>
        </div>
      </section>

      <section className="section">
        <h2>طلبات حجز</h2>
        {requests.length === 0 && <div className="empty">لا طلبات جديدة.</div>}
        {requests.map((r) => (
          <div key={r.booking_id} className="card">
            <div className="row between"><b>{r.student_name}</b>{r.starts_at && <span className="badge num">{time(r.starts_at)}</span>}</div>
            <p className="small">{r.offering_title}</p>
            {r.starts_at && <p className="small muted">{dayLong(r.starts_at)}</p>}
            <div className="row">
              <form action={respondAction}><input type="hidden" name="id" value={r.booking_id} /><input type="hidden" name="accept" value="1" /><button className="btn sm okb">قبول</button></form>
              <form action={respondAction}><input type="hidden" name="id" value={r.booking_id} /><input type="hidden" name="accept" value="0" /><button className="btn sm badb">رفض</button></form>
            </div>
          </div>
        ))}
      </section>

      <section className="section">
        <h2>الحصص القادمة</h2>
        {upcoming.length === 0 && <div className="empty">لا حصص مؤكدة قادمة.</div>}
        {upcoming.map((b) => (
          <div key={b.booking_id} className="card" style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
            <div className="stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
              <b>{b.student_name}</b>
              <span className="small muted">{b.offering_title}</span>
            </div>
            <span className="small num">{dayLong(b.starts_at!)} · {time(b.starts_at!)}</span>
          </div>
        ))}
      </section>

      {(courseSessions ?? []).length > 0 && (
        <section className="section">
          <h2>دوراتي في المعاهد</h2>
          {(courseSessions as any[]).map((s) => (
            <div key={s.id} className="card">
              <div className="row" style={{ flexWrap: "wrap" }}>
                <b>{s.offering.title}، اللقاء {s.seq}</b>
                {s.changed && <span className="badge">غيّر المعهد الموعد</span>}
              </div>
              <span className="small muted">{s.offering.institute?.name} · {dayLong(s.starts_at)} · <span className="num">{time(s.starts_at)}</span>{s.room ? ` · ${s.room.name}` : ""}</span>
            </div>
          ))}
        </section>
      )}

      <section className="section">
        <div className="row between">
          <h2>عروضي</h2>
          <Link className="back" href="/teach/new"><Icon name="plus" />عرض جديد</Link>
        </div>
        {mine.length === 0 && <div className="empty">لم تنشر أي عرض بعد. ابدأ بدرس خصوصي.</div>}
        {mine.map((o) => (
          <div key={o.id} className="stack" style={{ gap: 6 }}>
            <OfferCard o={o} showOwner={false} />
            <form action={toggleOfferingAction} className="row">
              <input type="hidden" name="id" value={o.id} />
              <input type="hidden" name="path" value="/teach" />
              <input type="hidden" name="active" value={o.active === false ? "1" : "0"} />
              <button className="link small">{o.active === false ? "إظهار العرض" : "إخفاء العرض"}</button>
            </form>
          </div>
        ))}
      </section>
    </div>
  );
}
