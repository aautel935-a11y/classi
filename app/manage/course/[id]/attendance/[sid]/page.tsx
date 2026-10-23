import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { saveAttendanceAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { dayLong, initials, time } from "@/lib/format";

export const dynamic = "force-dynamic";

export default async function Attendance({ params, searchParams }: { params: Promise<{ id: string; sid: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { id, sid } = await params;
  const sp = await searchParams;
  const path = `/manage/course/${id}/attendance/${sid}`;
  const { supabase } = await requireUser(path);
  const [{ data: s }, { data: roster }, { data: marks }] = await Promise.all([
    supabase.from("sessions").select("id,seq,starts_at,room:rooms(name),offering:offerings(title)").eq("id", sid).maybeSingle(),
    supabase.rpc("owner_bookings", { p_offering: id }),
    supabase.from("attendance").select("booking_id,present").eq("session_id", sid),
  ]);
  if (!s) notFound();
  const students = ((roster ?? []) as any[]).filter((b) => b.status === "confirmed");
  const mark = new Map((marks ?? []).map((m) => [m.booking_id, m.present]));
  return (
    <div className="wrap">
      <form action={saveAttendanceAction} className="section">
        <Link className="back" href={`/manage/course/${id}`}><Icon name="back" />رجوع</Link>
        <h1>الحضور</h1>
        <div className="card">
          <b>{(s as any).offering?.title}</b>
          <p className="small muted">اللقاء {s.seq} · {dayLong(s.starts_at)} {time(s.starts_at)}{(s as any).room ? ` · ${(s as any).room.name}` : ""}</p>
        </div>
        {sp.saved && <p className="okmsg">حُفظ الحضور.</p>}
        <input type="hidden" name="session_id" value={sid} />
        <input type="hidden" name="path" value={path} />
        {students.length === 0 ? (
          <div className="empty">لا طلاب مسجّلين بعد.</div>
        ) : (
          <div className="card" style={{ paddingBlock: 4 }}>
            {students.map((b) => {
              const v = mark.get(b.booking_id);
              return (
                <div key={b.booking_id} className="att">
                  <div className="avatar" style={{ width: 36, height: 36, fontSize: 13 }}>{initials(b.student_name)}</div>
                  <span className="name">{b.student_name}</span>
                  <div className="toggle2 radios">
                    <label><input type="radio" name={`b_${b.booking_id}`} value="p" defaultChecked={v !== false} />حاضر</label>
                    <label><input type="radio" name={`b_${b.booking_id}`} value="a" defaultChecked={v === false} />غائب</label>
                  </div>
                </div>
              );
            })}
          </div>
        )}
        {students.length > 0 && <button className="btn block">حفظ الحضور</button>}
      </form>
    </div>
  );
}
