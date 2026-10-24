import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon, Stars } from "@/components/Icon";
import { TypeBadge } from "@/components/OfferCard";
import { getSession } from "@/lib/session";
import { OFFERING_SELECT, PLACES, TYPES, ownerName, ownerOf, ownerPhoto, type Offering } from "@/lib/types";
import { Avatar } from "@/components/Avatar";
import { MessageButton } from "@/components/MessageButton";
import { dayLong, shekel, time } from "@/lib/format";
import { nextDays, privateSlots } from "@/lib/dates";
import { BookingFlow } from "./BookingFlow";

export const dynamic = "force-dynamic";

export default async function OfferPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, user } = await getSession();
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const { data } = await supabase.from("offerings").select(OFFERING_SELECT).eq("id", id).maybeSingle();
  if (!data) notFound();
  const o = data as unknown as Offering;
  const own = ownerOf(o);
  if (!own) notFound();
  const { data: mine } = user ? await supabase.rpc("is_offering_owner", { p_offering: o.id }) : { data: false };
  const { data: ownerAccount } = o.teacher
    ? await supabase.from("teachers").select("user_id").eq("id", o.teacher.id).maybeSingle()
    : await supabase.from("institutes").select("owner_id").eq("id", o.institute!.id).maybeSingle();
  const canMessage = !mine && !!((ownerAccount as any)?.user_id ?? (ownerAccount as any)?.owner_id);

  // what the booking sheet needs
  let slots: ReturnType<typeof privateSlots> = [];
  let groupSessions: { id: string; starts_at: string; taken: number }[] = [];
  let courseTaken = 0;
  let firstSession: string | null = null;

  if (o.type === "private" && o.teacher_id) {
    const days = nextDays(7);
    const [{ data: av }, { data: busy }] = await Promise.all([
      supabase.from("availability").select("weekday,start_time,end_time").eq("teacher_id", o.teacher_id),
      supabase.rpc("teacher_busy", { p_teacher: o.teacher_id, p_from: new Date().toISOString(), p_to: new Date(Date.now() + 9 * 864e5).toISOString() }),
    ]);
    slots = privateSlots(av ?? [], busy ?? [], o.minutes || 60, days);
  }
  if (o.type === "group" || o.type === "course") {
    const [{ data: ss }, { data: seats }] = await Promise.all([
      supabase.from("sessions").select("id,starts_at,seq").eq("offering_id", o.id).eq("cancelled", false).gt("starts_at", new Date().toISOString()).order("starts_at").limit(o.type === "group" ? 4 : 1),
      supabase.rpc("seats_overview"),
    ]);
    const rows = (seats ?? []) as { offering_id: string; session_id: string | null; taken: number }[];
    groupSessions = (ss ?? []).map((s) => ({ id: s.id, starts_at: s.starts_at, taken: rows.find((r) => r.session_id === s.id)?.taken ?? 0 }));
    courseTaken = rows.filter((r) => r.offering_id === o.id && !r.session_id).reduce((a, r) => a + r.taken, 0);
    firstSession = ss?.[0]?.starts_at ?? null;
  }
  const { data: children } = user ? await supabase.from("children").select("id,name,grade").order("created_at") : { data: [] };

  const full = o.type === "course" && o.seats != null && courseTaken >= o.seats;
  const facts: [string, string][] = [
    ["النوع", TYPES[o.type].name],
    ["المادة", o.subject?.name ?? "—"],
    ["المرحلة", o.level?.name ?? "—"],
    ["المكان", o.places.map((p) => PLACES[p]).join(" أو ")],
  ];
  if (o.schedule_note) facts.push(["الموعد", o.schedule_note]);
  if (o.type === "course" && firstSession) facts.push(["أول لقاء", `${dayLong(firstSession)} ${time(firstSession)}`]);
  if (o.sessions_count) facts.push(["عدد اللقاءات", `${o.sessions_count} لقاء`]);
  if (o.type === "course" && o.seats) facts.push(["المقاعد", `${courseTaken} من ${o.seats} محجوزة`]);
  if (o.lessons_count) facts.push(["الدروس", `${o.lessons_count} درساً مصوّراً`]);
  if (o.course_teacher) facts.push(["المعلم", `أ. ${o.course_teacher.name}`]);

  return (
    <div className="wrap">
      <div className="section">
        <div className="row">
          <TypeBadge type={o.type} />
          {full && <span className="badge bad">ممتلئ</span>}
        </div>
        <h1>{o.title}</h1>
        <Link className="card" href={o.teacher ? `/teacher/${own.id}` : `/institute/${own.id}`} style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
          <Avatar name={own.name} url={ownerPhoto(o)} inst={!!o.institute} />
          <div className="stack" style={{ gap: 2, minWidth: 0 }}>
            <b>{ownerName(o)}</b>
            <span className="small muted">{own.town}</span>
          </div>
          <span className="spacer">
            <Stars rating={own.rating} count={own.reviews_count} />
          </span>
        </Link>
        <div className="summary">
          {facts.map(([a, b]) => (
            <div key={a}>
              <span>{a}</span>
              <span>{b}</span>
            </div>
          ))}
          <div className="total">
            <span>السعر</span>
            <span className="num">
              {shekel(o.price)} {TYPES[o.type].unit}
            </span>
          </div>
        </div>
        {o.type === "private" && (
          <p className="note">
            <Icon name="clock" />
            إلغاء مجاني حتى 24 ساعة قبل الحصة.
          </p>
        )}
        {o.type === "recorded" ? (
          <p className="note">
            <Icon name="play" />
            رابط المحتوى يظهر في جدولك فور الشراء.
          </p>
        ) : o.places.includes("online") ? (
          <p className="note">
            <Icon name="monitor" />
            رابط زوم أو ميت يظهر في جدولك بعد تأكيد الحجز.
          </p>
        ) : null}
        {canMessage && (
          <MessageButton
            teacherId={o.teacher?.id}
            instituteId={o.teacher ? undefined : o.institute?.id}
            back={`/offer/${o.id}`}
            label={o.teacher ? "اسأل المعلم قبل الحجز" : "اسأل المعهد قبل التسجيل"}
          />
        )}
        {mine ? (
          <Link className="btn ghost block" href={`/manage/course/${o.id}`}>هذا عرضك: إدارة العرض</Link>
        ) : user ? (
          <BookingFlow
            offering={{ id: o.id, type: o.type, title: o.title, price: o.price, seats: o.seats, full, places: o.places }}
            slots={slots}
            groupSessions={groupSessions}
            kids={(children ?? []) as { id: string; name: string; grade: string | null }[]}
          />
        ) : (
          <Link className="btn block" href={`/login?next=/offer/${o.id}`}>
            سجّل الدخول للحجز
          </Link>
        )}
      </div>
    </div>
  );
}
