import Link from "next/link";
import { Icon } from "@/components/Icon";
import { addStaffAction, instituteSetupAction, updateInstituteAction } from "@/app/actions";
import { PhotoUpload } from "@/components/PhotoUpload";
import { requireUser } from "@/lib/session";
import { TOWNS } from "@/lib/types";
import { dayLong, time } from "@/lib/format";

export const dynamic = "force-dynamic";

export default async function Manage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase, user, profile } = await requireUser("/manage");
  const { data: inst } = await supabase.from("institutes").select("id,name,town,verify,bio,logo_url").eq("owner_id", user.id).maybeSingle();

  if (!inst) {
    return (
      <div className="wrap">
        <form action={instituteSetupAction} className="section">
          <h1>حساب المعهد</h1>
          <p className="muted">يظهر المعهد للطلاب بعد مراجعة الوثائق.</p>
          {sp.error && <p className="err">{sp.error}</p>}
          <label className="field" htmlFor="name">اسم المعهد<input id="name" name="name" required defaultValue={profile?.full_name ?? ""} /></label>
          <div className="typeform">
            <label className="field" htmlFor="town">البلد<select id="town" name="town" defaultValue={profile?.town ?? "باقة الغربية"}>{TOWNS.map((x) => <option key={x}>{x}</option>)}</select></label>
            <label className="field" htmlFor="rooms">عدد القاعات<input id="rooms" name="rooms" type="number" min={1} max={10} defaultValue={2} /></label>
          </div>
          <label className="field" htmlFor="bio">نبذة عن المعهد<textarea id="bio" name="bio" rows={3} /></label>
          <button className="btn block">إنشاء المعهد</button>
        </form>
      </div>
    );
  }

  const [{ data: courses }, { data: seats }, { data: rooms }, { data: staff }, { data: allTeachers }, { data: log }] = await Promise.all([
    supabase.from("offerings").select("id,title,seats,schedule_note,course_teacher:teachers!offerings_course_teacher_id_fkey(name)").eq("institute_id", inst.id).eq("type", "course").order("created_at"),
    supabase.rpc("seats_overview"),
    supabase.from("rooms").select("id,name").eq("institute_id", inst.id).order("name"),
    supabase.from("institute_teachers").select("teacher:teachers(id,name)").eq("institute_id", inst.id),
    supabase.from("teachers").select("id,name,town").order("name"),
    supabase.from("change_log").select("id,body,notified_count,created_at").order("created_at", { ascending: false }).limit(5),
  ]);
  const ids = (courses ?? []).map((c) => c.id);
  const { data: todaySessions } = ids.length
    ? await supabase
        .from("sessions")
        .select("id,seq,starts_at,offering_id,room:rooms(name),offering:offerings(title)")
        .in("offering_id", ids)
        .eq("cancelled", false)
        .gte("starts_at", new Date().toISOString())
        .order("starts_at")
        .limit(5)
    : { data: [] as any[] };
  const taken = (oid: string) =>
    ((seats ?? []) as { offering_id: string; session_id: string | null; taken: number }[]).filter((r) => r.offering_id === oid && !r.session_id).reduce((a, r) => a + r.taken, 0);
  const staffIds = new Set((staff ?? []).map((s: any) => s.teacher?.id));

  return (
    <div className="wrap">
      <div className="section">
        <h1>{inst.name}</h1>
        {inst.verify !== "verified" && <p className="note"><Icon name="shield" />المعهد بانتظار التوثيق. الدورات تظهر للطلاب بعد التوثيق.</p>}
        <div className="stats">
          <div className="stat hl"><b className="num">{ids.reduce((a, id) => a + taken(id), 0)}</b><span>طالباً مسجّلاً</span></div>
          <div className="stat"><b className="num">{ids.length}</b><span>دورات</span></div>
          <div className="stat"><b className="num">{(rooms ?? []).length}</b><span>قاعات</span></div>
        </div>
      </div>

      <section className="section">
        <h2>ملف المعهد</h2>
        {sp.ok && <p className="okmsg">حُفظ ملف المعهد.</p>}
        <div className="card">
          <PhotoUpload kind="institute" name={inst.name} current={inst.logo_url} />
          <details>
            <summary className="link small">تعديل الاسم والنبذة</summary>
            <form action={updateInstituteAction} className="formstack" style={{ marginTop: 12 }}>
              <label className="field" htmlFor="i-name">اسم المعهد<input id="i-name" name="name" required defaultValue={inst.name} /></label>
              <label className="field" htmlFor="i-town">البلد<select id="i-town" name="town" defaultValue={inst.town}>{TOWNS.map((x) => <option key={x}>{x}</option>)}</select></label>
              <label className="field" htmlFor="i-bio">نبذة<textarea id="i-bio" name="bio" rows={3} defaultValue={inst.bio} /></label>
              <button className="btn">حفظ</button>
            </form>
          </details>
          <Link className="link small" href={`/institute/${inst.id}`}>كيف يرى الطلاب المعهد</Link>
        </div>
      </section>

      <section className="section">
        <div className="row between">
          <h2>الدورات</h2>
          <Link className="back" href="/manage/new-course"><Icon name="plus" />دورة جديدة</Link>
        </div>
        {(courses ?? []).length === 0 && <div className="empty">لا دورات بعد. أنشئ أول دورة وحدد أيامها وساعتها.</div>}
        {(courses ?? []).map((c: any) => {
          const n = taken(c.id);
          return (
            <Link key={c.id} href={`/manage/course/${c.id}`} className="card">
              <div className="row between"><b>{c.title}</b>{c.seats && n >= c.seats && <span className="badge bad">ممتلئ</span>}</div>
              <p className="small muted">{c.course_teacher ? `أ. ${c.course_teacher.name} · ` : ""}{c.schedule_note}</p>
              <div className="row between small num"><span>{n} من {c.seats} مقعد</span><span className="link">المواعيد والحضور</span></div>
              <div className="seats"><i style={{ width: `${Math.min(100, (n / (c.seats || 1)) * 100)}%` }} /></div>
            </Link>
          );
        })}
      </section>

      {(todaySessions ?? []).length > 0 && (
        <section className="section">
          <h2>اللقاءات القادمة</h2>
          {(todaySessions as any[]).map((s) => (
            <div key={s.id} className="card" style={{ flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 12 }}>
              <div style={{ minWidth: 0 }}><b>{s.room?.name ?? "بدون قاعة"}</b><p className="small muted">{s.offering?.title}، اللقاء {s.seq}</p></div>
              <span className="num small">{dayLong(s.starts_at)} · {time(s.starts_at)}</span>
            </div>
          ))}
          <p className="note"><Icon name="check" />النظام يمنع حجز قاعة أو معلم في وقتين متعارضين.</p>
        </section>
      )}

      {(log ?? []).length > 0 && (
        <section className="section">
          <h2>سجلّ تغييرات المواعيد</h2>
          {(log ?? []).map((l) => (
            <div key={l.id} className="card">
              <p className="small">{l.body}</p>
              <p className="small muted">أُبلغ {l.notified_count} · {dayLong(l.created_at)} {time(l.created_at)}</p>
            </div>
          ))}
        </section>
      )}

      <section className="section">
        <h2>معلمو المعهد</h2>
        <div className="row" style={{ flexWrap: "wrap" }}>
          {(staff ?? []).map((s: any) => s.teacher && <span key={s.teacher.id} className="badge">أ. {s.teacher.name}</span>)}
          {(staff ?? []).length === 0 && <span className="small muted">لم تضف معلمين بعد.</span>}
        </div>
        <form action={addStaffAction} className="row">
          <select name="teacher_id" aria-label="اختر معلماً" style={{ flex: 1, minWidth: 0, padding: 10, borderRadius: "var(--r-sm)", border: "1px solid var(--line)", background: "var(--card)" }}>
            {(allTeachers ?? []).filter((t) => !staffIds.has(t.id)).map((t) => <option key={t.id} value={t.id}>{t.name} · {t.town}</option>)}
          </select>
          <button className="btn sm">إضافة</button>
        </form>
      </section>
    </div>
  );
}
