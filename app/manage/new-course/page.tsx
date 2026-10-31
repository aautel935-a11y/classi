import { newCourseAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { redirect } from "next/navigation";
import { isoDay } from "@/lib/format";
import { ErrorNote } from "@/components/ErrorNote";

export const dynamic = "force-dynamic";
const DAYS = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة"];

export default async function NewCourse({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase, user } = await requireUser("/manage/new-course");
  const { data: inst } = await supabase.from("institutes").select("id").eq("owner_id", user.id).maybeSingle();
  if (!inst) redirect("/manage");
  const [{ data: subjects }, { data: levels }, { data: rooms }, { data: staff }] = await Promise.all([
    supabase.from("subjects").select("id,name").order("id"),
    supabase.from("levels").select("id,name").order("sort"),
    supabase.from("rooms").select("id,name").eq("institute_id", inst.id).order("name"),
    supabase.from("institute_teachers").select("teacher:teachers(id,name)").eq("institute_id", inst.id).eq("status", "accepted"),
  ]);
  const start = isoDay(new Date(Date.now() + 7 * 864e5));
  return (
    <div className="wrap">
      <form action={newCourseAction} className="section">
        <h1>دورة جديدة</h1>
        <ErrorNote msg={sp.error} />
        <label className="field" htmlFor="title">اسم الدورة<input id="title" name="title" required minLength={3} placeholder="دورة بجروت رياضيات 5 وحدات" /></label>
        <div className="typeform">
          <label className="field" htmlFor="subject_id">المادة<select id="subject_id" name="subject_id">{(subjects ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
          <label className="field" htmlFor="level_id">المرحلة<select id="level_id" name="level_id">{(levels ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
          <label className="field" htmlFor="teacher_id">
            المعلم
            <select id="teacher_id" name="teacher_id">
              <option value="">لاحقاً</option>
              {(staff ?? []).map((s: any) => s.teacher && <option key={s.teacher.id} value={s.teacher.id}>{s.teacher.name}</option>)}
            </select>
          </label>
          <label className="field" htmlFor="room_id">القاعة<select id="room_id" name="room_id">{(rooms ?? []).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select></label>
          <label className="field" htmlFor="price">سعر الدورة (₪)<input id="price" name="price" type="number" min={0} required defaultValue={850} /></label>
          <label className="field" htmlFor="seats">المقاعد<input id="seats" name="seats" type="number" min={1} defaultValue={14} /></label>
          <label className="field" htmlFor="start">تاريخ البداية<input id="start" name="start" type="date" required defaultValue={start} /></label>
          <label className="field" htmlFor="time">الساعة<input id="time" name="time" type="time" required defaultValue="17:00" /></label>
          <label className="field" htmlFor="minutes">مدة اللقاء<select id="minutes" name="minutes" defaultValue="90">{[45, 60, 90, 120, 150].map((m) => <option key={m} value={m}>{m === 60 ? "ساعة" : m === 90 ? "ساعة ونصف" : m === 120 ? "ساعتان" : `${m} دقيقة`}</option>)}</select></label>
          <label className="field" htmlFor="sessions">عدد اللقاءات<input id="sessions" name="sessions" type="number" min={1} max={60} defaultValue={12} /></label>
        </div>
        <fieldset>
          <legend>أيام اللقاءات</legend>
          <div className="weekdays">
            {DAYS.map((d, i) => (
              <label key={d}>
                <input type="checkbox" name="weekdays" value={i} defaultChecked={i === 0 || i === 3} />
                {d}
              </label>
            ))}
          </div>
        </fieldset>
        <label className="row"><input type="checkbox" name="online" /> يمكن الحضور أونلاين أيضاً</label>
        <button className="btn block">إنشاء الدورة وجدولة اللقاءات</button>
      </form>
    </div>
  );
}
