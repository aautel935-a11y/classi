import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { requireUser } from "@/lib/session";
import { dayLong, isoDay, time } from "@/lib/format";
import { EditSession } from "./EditSession";

export const dynamic = "force-dynamic";

export default async function CoursePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase } = await requireUser(`/manage/course/${id}`);
  const { data: o } = await supabase
    .from("offerings")
    .select("id,title,seats,institute_id,teacher_id,course_teacher:teachers!offerings_course_teacher_id_fkey(name)")
    .eq("id", id)
    .maybeSingle();
  if (!o) notFound();
  const [{ data: sessions }, { data: rooms }, { data: roster }] = await Promise.all([
    supabase.from("sessions").select("id,seq,starts_at,changed,cancelled,room_id,room:rooms(name)").eq("offering_id", id).order("seq"),
    o.institute_id ? supabase.from("rooms").select("id,name").eq("institute_id", o.institute_id).order("name") : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    supabase.rpc("owner_bookings", { p_offering: id }),
  ]);
  const enrolled = ((roster ?? []) as any[]).filter((b) => b.status === "confirmed" || b.status === "pending");
  const now = new Date().toISOString();

  return (
    <div className="wrap">
      <div className="section">
        <Link className="back" href={o.institute_id ? "/manage" : "/teach"}><Icon name="back" />رجوع</Link>
        <h1>{o.title}</h1>
        <p className="small muted">
          {(o as any).course_teacher ? `أ. ${(o as any).course_teacher.name} · ` : ""}
          {enrolled.length} طالباً مسجّلاً · {(sessions ?? []).length} لقاء
        </p>
        <p className="note"><Icon name="bell" />أي تغيير في الموعد أو القاعة يصل فوراً للمعلم وللطلاب وأولياء أمورهم في إشعاراتهم وجداولهم.</p>
        {(sessions ?? []).map((s: any) => (
          <div key={s.id} className="card" style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
            <div className="stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
              <div className="row" style={{ flexWrap: "wrap" }}>
                <b>اللقاء {s.seq}</b>
                {s.changed && <span className="badge">تغيّر الموعد</span>}
                {s.starts_at < now && <span className="badge ok">انتهى</span>}
              </div>
              <span className="small muted">{dayLong(s.starts_at)} · <span className="num">{time(s.starts_at)}</span>{s.room ? ` · ${s.room.name}` : ""}</span>
            </div>
            {s.starts_at < now ? (
              <Link className="btn sm ghost" href={`/manage/course/${id}/attendance/${s.id}`}>الحضور</Link>
            ) : (
              <div className="row" style={{ gap: 6 }}>
                <Link className="btn sm ghost" href={`/manage/course/${id}/attendance/${s.id}`}>الحضور</Link>
                <EditSession
                  path={`/manage/course/${id}`}
                  session={{ id: s.id, seq: s.seq, day: isoDay(s.starts_at), time: time(s.starts_at), roomId: s.room_id }}
                  rooms={(rooms ?? []) as { id: string; name: string }[]}
                  laterCount={(sessions ?? []).filter((x: any) => x.seq >= s.seq).length}
                  students={enrolled.length}
                />
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
