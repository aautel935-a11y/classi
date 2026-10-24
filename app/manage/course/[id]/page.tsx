import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { saveLinkAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { PAY_LABEL, PLACES, TYPES, type OfferingType, type Place } from "@/lib/types";
import { dayLong, isoDay, time } from "@/lib/format";
import { EditSession } from "./EditSession";

export const dynamic = "force-dynamic";

/** One page to run any offer: its Zoom/content link, its meetings, and who booked. */
export default async function ManageOffer({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { id } = await params;
  const sp = await searchParams;
  const path = `/manage/course/${id}`;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const { supabase } = await requireUser(path);
  const { data: o } = await supabase
    .from("offerings")
    .select("id,type,title,seats,places,institute_id,teacher_id,course_teacher:teachers!offerings_course_teacher_id_fkey(name)")
    .eq("id", id)
    .maybeSingle();
  if (!o) notFound();
  const [{ data: staff }, { data: owner }] = await Promise.all([
    supabase.rpc("is_offering_staff", { p_offering: id }),
    supabase.rpc("is_offering_owner", { p_offering: id }),
  ]);
  if (!staff) notFound();
  const [{ data: sessions }, { data: rooms }, { data: roster }, { data: link }] = await Promise.all([
    supabase.from("sessions").select("id,seq,starts_at,changed,cancelled,room_id,room:rooms(name)").eq("offering_id", id).order("seq"),
    o.institute_id ? supabase.from("rooms").select("id,name").eq("institute_id", o.institute_id).order("name") : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    supabase.rpc("owner_bookings", { p_offering: id }),
    supabase.from("offering_links").select("url,note").eq("offering_id", id).maybeSingle(),
  ]);
  const type = o.type as OfferingType;
  const places = o.places as Place[];
  const list = ((roster ?? []) as any[]).filter((b) => b.status === "confirmed" || b.status === "pending");
  const now = new Date().toISOString();
  const needsLink = type === "recorded" || places.includes("online");
  const backHref = o.institute_id && owner ? "/manage" : "/teach";

  return (
    <div className="wrap">
      <div className="section">
        <Link className="back" href={backHref}><Icon name="back" />رجوع</Link>
        <span className="badge" style={{ alignSelf: "flex-start" }}><Icon name={TYPES[type].icon} />{TYPES[type].name}</span>
        <h1>{o.title}</h1>
        <p className="small muted">
          {(o as any).course_teacher ? `أ. ${(o as any).course_teacher.name} · ` : ""}
          {list.length} {type === "private" ? "حجز" : "طالباً"}
          {(sessions ?? []).length ? ` · ${(sessions ?? []).length} لقاء` : ""}
        </p>
        {sp.saved && <p className="okmsg">حُفظ الرابط. يراه الطلاب المؤكَّدون في جدولهم.</p>}
        {sp.error && <p className="err">{sp.error}</p>}
      </div>

      {needsLink && (
        <section className="section">
          <h2>{type === "recorded" ? "رابط المحتوى" : "رابط اللقاء أونلاين"}</h2>
          <form action={saveLinkAction} className="card formstack">
            <input type="hidden" name="offering_id" value={id} />
            <input type="hidden" name="path" value={path} />
            <label className="field" htmlFor="url">
              {type === "recorded" ? "رابط الفيديوهات أو الملفات (YouTube غير مُدرج، Google Drive…)" : "رابط زوم أو Google Meet الثابت"}
              <input id="url" name="url" type="url" dir="ltr" placeholder={type === "recorded" ? "https://drive.google.com/…" : "https://zoom.us/j/…"} defaultValue={link?.url ?? ""} />
            </label>
            <label className="field" htmlFor="note">
              ملاحظة للطلاب (اختياري)
              <input id="note" name="note" placeholder={type === "recorded" ? "مثلاً: ابدأ من الفيديو الأول" : "مثلاً: كلمة سر اللقاء 1234"} defaultValue={link?.note ?? ""} />
            </label>
            <p className="note"><Icon name="shield" />الرابط لا يظهر للعامة. يراه فقط من تأكّد حجزه، في صفحة جدولي.</p>
            <button className="btn">{link ? "تحديث الرابط" : "حفظ الرابط"}</button>
          </form>
        </section>
      )}

      {(sessions ?? []).length > 0 && (
        <section className="section">
          <h2>اللقاءات</h2>
          {owner && <p className="note"><Icon name="bell" />أي تغيير في الموعد أو القاعة يصل فوراً للمعلم وللطلاب وأولياء أمورهم.</p>}
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
              <div className="row" style={{ gap: 6 }}>
                <Link className="btn sm ghost" href={`/manage/course/${id}/attendance/${s.id}`}>الحضور</Link>
                {owner && s.starts_at >= now && (
                  <EditSession
                    path={path}
                    session={{ id: s.id, seq: s.seq, day: isoDay(s.starts_at), time: time(s.starts_at), roomId: s.room_id }}
                    rooms={(rooms ?? []) as { id: string; name: string }[]}
                    laterCount={(sessions ?? []).filter((x: any) => x.seq >= s.seq).length}
                    students={list.length}
                  />
                )}
              </div>
            </div>
          ))}
        </section>
      )}

      <section className="section">
        <h2>{type === "private" ? "الحجوزات" : "الطلاب"}</h2>
        {list.length === 0 && <div className="empty">لا حجوزات بعد.</div>}
        {list.map((b) => (
          <div key={b.booking_id} className="card" style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
            <div className="stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
              <b>{b.student_name}</b>
              <span className="small muted">
                {b.starts_at ? `${dayLong(b.starts_at)} · ${time(b.starts_at)} · ` : ""}
                {b.mode ? (b.mode === "online" ? "أونلاين" : PLACES[b.mode as Place]) : ""}
                {b.weekly ? " · يريد نفس الموعد أسبوعياً" : ""}
              </span>
            </div>
            <div className="stack" style={{ gap: 4, alignItems: "flex-end" }}>
              <span className={`badge ${b.status === "confirmed" ? "ok" : ""}`}>{b.status === "confirmed" ? "مؤكد" : "بانتظار ردّك"}</span>
              <span className="small muted">{PAY_LABEL[b.pay_method] ?? b.pay_method}</span>
            </div>
          </div>
        ))}
      </section>
    </div>
  );
}
