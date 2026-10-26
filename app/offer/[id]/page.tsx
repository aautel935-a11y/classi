import { offerMeta } from "@/lib/meta";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon, Stars } from "@/components/Icon";
import { TypeBadge } from "@/components/OfferCard";
import { getSession } from "@/lib/session";
import { OFFERING_SELECT, PLACES, TYPES, ownerName, ownerOf, ownerPhoto, type Offering, durationLabel } from "@/lib/types";
import { Avatar } from "@/components/Avatar";
import { MessageButton } from "@/components/MessageButton";
import { ReportButton } from "@/components/ReportButton";
import { AdminQuick } from "@/components/AdminQuick";
import { dayLong, shekel, time } from "@/lib/format";
import { nextDays, privateSlots } from "@/lib/dates";
import { BookingFlow } from "./BookingFlow";
import { WaitlistJoin } from "./WaitlistJoin";
import { buyPackageAction, leaveWaitlistAction } from "@/app/actions";
import { IntroVideo } from "@/components/IntroVideo";
import { WhatsAppButton } from "@/components/WhatsAppButton";
import { PayBadge, PayForStudent } from "@/components/Pay";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }) {
  return offerMeta((await params).id);
}

export default async function OfferPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { id } = await params;
  const sp = await searchParams;
  const { supabase, user, profile } = await getSession();
  const isAdmin = !!profile?.roles?.includes("admin");
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const { data } = await supabase.from("offerings").select(OFFERING_SELECT).eq("id", id).maybeSingle();
  if (!data) notFound();
  const o = data as unknown as Offering;
  const own = ownerOf(o);
  if (!own) notFound();
  // Everything else the page needs, fetched at the same time.
  const empty = Promise.resolve({ data: null as any });
  const now = new Date().toISOString();
  const [mineR, ownerR, avR, busyR, ssR, seatsR, kidsR, bufR, wlR, pkR] = await Promise.all([
    user ? supabase.rpc("is_offering_owner", { p_offering: o.id }) : empty,
    o.teacher
      ? supabase.from("teachers").select("user_id,intro_video_url,whatsapp").eq("id", o.teacher.id).maybeSingle()
      : supabase.from("institutes").select("owner_id,whatsapp").eq("id", o.institute!.id).maybeSingle(),
    o.type === "private" && o.teacher_id ? supabase.from("availability").select("weekday,start_time,end_time").eq("teacher_id", o.teacher_id) : empty,
    o.type === "private" && o.teacher_id
      ? supabase.rpc("teacher_busy", { p_teacher: o.teacher_id, p_from: now, p_to: new Date(Date.now() + 9 * 864e5).toISOString() })
      : empty,
    o.type === "group" || o.type === "course"
      ? supabase.from("sessions").select("id,starts_at,seq").eq("offering_id", o.id).eq("cancelled", false).gt("starts_at", now).order("starts_at").limit(o.type === "group" ? 4 : 1)
      : empty,
    o.type === "group" || o.type === "course" ? supabase.rpc("seats_overview") : empty,
    user ? supabase.from("children").select("id,name,grade").order("created_at") : empty,
    o.type === "private" && o.teacher_id ? supabase.rpc("teacher_buffer", { p_teacher: o.teacher_id }) : empty,
    user ? supabase.rpc("my_waitlist") : empty,
    user && o.package_enabled ? supabase.from("lesson_packages").select("id,child_id,remaining,size,price,pay_status,pay_method").eq("offering_id", o.id).neq("status", "cancelled").eq("user_id", user.id) : empty,
  ]);
  const mine = mineR.data;
  const ownerAccount = ownerR.data as any;
  const canMessage = !mine && !!(ownerAccount?.user_id ?? ownerAccount?.owner_id);
  const slots = o.type === "private" ? privateSlots(avR.data ?? [], busyR.data ?? [], o.minutes || 60, nextDays(7), Number(bufR.data ?? 0)) : [];
  const rows = (seatsR.data ?? []) as { offering_id: string; session_id: string | null; taken: number }[];
  const ss = (ssR.data ?? []) as { id: string; starts_at: string }[];
  const groupSessions = ss.map((x) => ({ id: x.id, starts_at: x.starts_at, taken: rows.find((r) => r.session_id === x.id)?.taken ?? 0 }));
  const courseTaken = rows.filter((r) => r.offering_id === o.id && !r.session_id).reduce((a, r) => a + r.taken, 0);
  const firstSession = ss[0]?.starts_at ?? null;
  const children = kidsR.data;
  const kidList = (children ?? []) as { id: string; name: string; grade: string | null }[];
  // Who may still take the trial lesson (once per student with this teacher).
  const trialFor: string[] = [];
  if (user && o.type === "private" && o.trial_price != null) {
    const who = [null, ...kidList.map((k) => k.id)];
    const res = await Promise.all(who.map((c) => supabase.rpc("trial_available", { p_offering: o.id, p_child: c })));
    res.forEach((r, i) => { if (r.data) trialFor.push(who[i] ?? "self"); });
  }
  const pkRows = (pkR.data ?? []) as { id: string; child_id: string | null; remaining: number; size: number; price: number; pay_status: string; pay_method: string }[];
  const myPackages = pkRows.filter((p) => p.remaining > 0).map((p) => ({ who: p.child_id ?? "self", remaining: p.remaining, size: p.size }));
  const unpaidPkgs = pkRows.filter((p) => p.pay_status !== "paid");
  const { data: payNums } = unpaidPkgs.length ? await supabase.rpc("my_pay_numbers") : { data: null };
  const payNum = ((payNums ?? []) as { offering_id: string; owner_name: string; bit_phone: string | null }[]).find((x) => x.offering_id === o.id);
  const pkgOn = !!(o.package_enabled && o.package_size && o.package_price && (o.type === "private" || o.type === "group"));
  const pkgSave = pkgOn ? o.package_size! * o.price - o.package_price! : 0;

  const full = o.type === "course" && o.seats != null && courseTaken >= o.seats;
  // Nothing left to book: full course, every upcoming group meeting full, or no free private hours.
  const noRoom =
    full ||
    (o.type === "group" && o.seats != null && groupSessions.length > 0 && groupSessions.every((g) => g.taken >= o.seats!)) ||
    (o.type === "private" && slots.every((s) => s.busy));
  const myWait = ((wlR.data ?? []) as { id: string; offering_id: string; status: string; pos: number | null; child_name: string | null }[]).filter((w) => w.offering_id === o.id && w.status !== "declined");
  const notified = myWait.find((w) => w.status === "notified");
  // Still in line: waiting, answered, or told of a seat that someone else took first.
  const waiting = myWait.find((w) => w.status === "waiting" || w.status === "accepted") ?? (noRoom ? notified : undefined);
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
        <div className="row" style={{ flexWrap: "wrap" }}>
          <TypeBadge type={o.type} />
          {o.type === "private" && o.auto_confirm && <span className="badge ok"><Icon name="check" />تأكيد فوري</span>}
          {o.allow_weekly && (o.type === "private" || o.type === "group") && <span className="badge"><Icon name="cal" />يمكن الحجز أسبوعياً</span>}
          {noRoom && o.type !== "private" && <span className="badge bad">ممتلئ</span>}
          {o.type === "private" && o.trial_price != null && <span className="badge ok">{o.trial_price === 0 ? "حصة تجريبية مجانية" : `حصة تجريبية بـ ${o.trial_price} ₪`}</span>}
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
              {shekel(o.price)} {TYPES[o.type].unit}{o.type !== "recorded" && o.minutes ? ` (${durationLabel(o.minutes)})` : ""}
            </span>
          </div>
        </div>
        {sp.waiting && <p className="okmsg">أُضفت لقائمة الانتظار (رقم {sp.waiting}). نخبرك فور توفّر مكان.</p>}
        {sp.left && <p className="okmsg">خرجت من قائمة الانتظار.</p>}
        {o.type === "private" && (
          <p className="note">
            <Icon name="clock" />
            {o.auto_confirm ? "الحجز يُثبَّت فوراً دون انتظار موافقة المعلم. " : "يؤكد المعلم الحجز بعد الطلب. "}إلغاء مجاني حتى 24 ساعة قبل الحصة.
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
        <IntroVideo url={ownerAccount?.intro_video_url} name={o.teacher ? `أ. ${o.teacher.name}` : ownerName(o)} />
        {pkgOn && !mine && (
          <div className="card package-card">
            <div className="row between">
              <b>رزمة {o.package_size} حصص</b>
              <span className="num"><b>{shekel(o.package_price!)}</b>{pkgSave > 0 && <span className="small muted"> بدل {shekel(o.package_size! * o.price)}</span>}</span>
            </div>
            <span className="small muted">
              {pkgSave > 0 ? `توفّر ${shekel(pkgSave)}. ` : ""}كل حجز يُخصم من الرزمة تلقائياً، والحصة الملغاة ترجع إليها.
            </span>
            {sp.package && <p className="okmsg">الرزمة جاهزة. احجز حصصك وستُخصم منها.</p>}
            {sp.package_error && <p className="err">{sp.package_error}</p>}
            {myPackages.map((p) => (
              <span key={p.who} className="badge ok" style={{ alignSelf: "flex-start" }}>
                رزمتك{p.who !== "self" ? ` لـ${kidList.find((k) => k.id === p.who)?.name ?? ""}` : ""}: بقي {p.remaining} من {p.size}
              </span>
            ))}
            {unpaidPkgs.map((p) => (
              <div key={p.id} className="stack" style={{ gap: 6 }}>
                <span className="row small" style={{ gap: 6 }}>دفع الرزمة: <PayBadge status={p.pay_status} method={p.pay_method} /></span>
                <PayForStudent packageId={p.id} status={p.pay_status} method={p.pay_method} amount={p.price} bit={payNum?.bit_phone} owner={payNum?.owner_name} back={`/offer/${o.id}`} />
              </div>
            ))}
            {sp.paid_reported && <p className="okmsg">أبلغنا المعلم بالتحويل.</p>}
            {user ? (
              <details>
                <summary className="link small">شراء رزمة</summary>
                <form action={buyPackageAction} className="formstack" style={{ marginTop: 8 }}>
                  <input type="hidden" name="offering_id" value={o.id} />
                  <label className="field">
                    لمن الرزمة؟
                    <select name="who">
                      <option value="self">أنا</option>
                      {kidList.map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}
                    </select>
                  </label>
                  <label className="field">
                    الدفع
                    <select name="pay"><option value="bit">Bit</option><option value="cash">نقداً للمعلم</option></select>
                  </label>
                  <p className="small muted">الدفع للمعلم مباشرة في هذه المرحلة. يصله إشعار بشرائك.</p>
                  <button className="btn sm">تأكيد شراء الرزمة</button>
                </form>
              </details>
            ) : (
              <Link className="link small" href={`/login?next=/offer/${o.id}`}>سجّل الدخول لشراء رزمة</Link>
            )}
          </div>
        )}
        {isAdmin && <AdminQuick kind="offering" id={o.id} hidden={!!(o as any).moderation_hidden} back={`/offer/${o.id}`} userId={ownerAccount?.user_id ?? ownerAccount?.owner_id} />}
        {canMessage && (
          <MessageButton
            teacherId={o.teacher?.id}
            instituteId={o.teacher ? undefined : o.institute?.id}
            back={`/offer/${o.id}`}
            label={o.teacher ? "اسأل المعلم قبل الحجز" : "اسأل المعهد قبل التسجيل"}
          />
        )}
        {!mine && <WhatsAppButton phone={ownerAccount?.whatsapp} text={`مرحباً، بخصوص «${o.title}» في Classi:`} />}
        {mine ? (
          <Link className="btn ghost block" href={`/manage/course/${o.id}`}>هذا عرضك: إدارة العرض</Link>
        ) : user && waiting ? (
          <div className="card">
            <b><Icon name="clock" /> {waiting.status === "accepted" ? "ردّ المعلم على طلبك" : `أنت رقم ${waiting.pos} في قائمة الانتظار`}</b>
            <span className="small muted">
              {waiting.status === "accepted"
                ? "تابع معه في الرسائل لتتفقا على موعد."
                : `${waiting.status === "notified" ? "المكان الذي تحرّر حُجز قبلك، وما زلت في القائمة. " : ""}${waiting.child_name ? `لـ${waiting.child_name}. ` : ""}نرسل لك إشعاراً فور توفّر مكان أو عند ردّ ${o.institute ? "المعهد" : "المعلم"}.`}
            </span>
            {waiting.status === "accepted" ? (
              <Link className="btn sm" href="/messages">الرسائل</Link>
            ) : (
              <form action={leaveWaitlistAction}>
                <input type="hidden" name="id" value={waiting.id} />
                <input type="hidden" name="back" value={`/offer/${o.id}`} />
                <button className="link small" style={{ color: "var(--bad)" }}>الخروج من القائمة</button>
              </form>
            )}
          </div>
        ) : user && noRoom ? (
          <WaitlistJoin offering={{ id: o.id, type: o.type }} kids={(children ?? []) as { id: string; name: string }[]} owner={o.institute ? "institute" : "teacher"} />
        ) : user ? (
          <>
          {notified && <p className="okmsg">تحرّر مكان لك من قائمة الانتظار. احجز الآن قبل غيرك.</p>}
          <BookingFlow
            offering={{ id: o.id, type: o.type, title: o.title, price: o.price, seats: o.seats, full, places: o.places, autoConfirm: !!o.auto_confirm, allowWeekly: !!o.allow_weekly }}
            slots={slots}
            groupSessions={groupSessions}
            kids={kidList}
            trialFor={trialFor}
            trialPrice={o.trial_price ?? null}
            packages={myPackages}
          />
          </>
        ) : (
          <Link className="btn block" href={`/login?next=/offer/${o.id}`}>
            سجّل الدخول للحجز
          </Link>
        )}
        {!mine && <ReportButton type="offering" id={o.id} back={`/offer/${o.id}`} flash={{ ok: sp.reported, error: sp.report_error }} />}
      </div>
    </div>
  );
}
