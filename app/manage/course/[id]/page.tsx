import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { cancelPackageAction, saveLinkAction, startBookingConversationAction, updateOfferingAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { PAY_LABEL, PLACES, TYPES, type OfferingType, type Place } from "@/lib/types";
import { dayLong, isoDay, time } from "@/lib/format";
import { EditSession } from "./EditSession";
import { OfferExtras } from "@/components/OfferExtras";
import { ConfirmPay, PayBadge } from "@/components/Pay";
import { WaitlistOwner, type WRow } from "@/components/WaitlistOwner";

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
    .select("id,type,title,price,seats,places,lessons_count,subject_id,level_id,course_teacher_id,institute_id,teacher_id,auto_confirm,allow_weekly,trial_price,package_enabled,package_size,package_price,course_teacher:teachers!offerings_course_teacher_id_fkey(name)")
    .eq("id", id)
    .maybeSingle();
  if (!o) notFound();
  const [{ data: staff }, { data: owner }] = await Promise.all([
    supabase.rpc("is_offering_staff", { p_offering: id }),
    supabase.rpc("is_offering_owner", { p_offering: id }),
  ]);
  if (!staff) notFound();
  const [{ data: sessions }, { data: rooms }, { data: roster }, { data: link }, { data: subjects }, { data: levels }, { data: staffList }, { data: wl }, { data: pk }] = await Promise.all([
    supabase.from("sessions").select("id,seq,starts_at,changed,cancelled,room_id,room:rooms(name)").eq("offering_id", id).order("seq"),
    o.institute_id ? supabase.from("rooms").select("id,name").eq("institute_id", o.institute_id).order("name") : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    supabase.rpc("owner_bookings", { p_offering: id }),
    supabase.from("offering_links").select("url,note").eq("offering_id", id).maybeSingle(),
    supabase.from("subjects").select("id,name").order("id"),
    supabase.from("levels").select("id,name").order("sort"),
    o.institute_id ? supabase.from("institute_teachers").select("teacher:teachers(id,name)").eq("institute_id", o.institute_id) : Promise.resolve({ data: [] as any[] }),
    supabase.rpc("owner_waitlist", { p_offering: id }),
    supabase.rpc("owner_packages", { p_offering: id }),
  ]);
  const placeNow = (o.places as string[]).includes("home") && (o.places as string[]).includes("online") ? "both" : (o.places as string[])[0];
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
        {sp.saved === "link" && <p className="okmsg">حُفظ الرابط. يراه الطلاب المؤكَّدون في جدولهم.</p>}
        {sp.ok === "payment" && <p className="okmsg">حُدّثت حالة الدفع.</p>}
        {sp.saved === "package" && <p className="okmsg">أُلغيت الرزمة ووصل ولي الأمر إشعار. الحصص القادمة بقيت محجوزة بالسعر العادي.</p>}
        {sp.saved === "offer" && <p className="okmsg">حُفظت التعديلات. السعر الجديد يسري على الحجوزات القادمة فقط.</p>}
        {sp.error && <p className="err">{sp.error}</p>}
      </div>

      {owner && (
        <section className="section">
          <details className="card" open={sp.edit === "1"}>
            <summary className="row between" style={{ cursor: "pointer" }}><b>تعديل العرض</b><span className="link small">السعر والتفاصيل</span></summary>
            <form action={updateOfferingAction} className="formstack" style={{ marginTop: 12 }}>
              <input type="hidden" name="id" value={id} />
              <label className="field" htmlFor="ed-title">العنوان<input id="ed-title" name="title" required minLength={3} defaultValue={o.title} /></label>
              <div className="typeform">
                <label className="field" htmlFor="ed-price">
                  السعر (₪) {TYPES[type].unit}
                  <input id="ed-price" name="price" type="number" min={0} required defaultValue={o.price} />
                </label>
                <label className="field" htmlFor="ed-subject">المادة<select id="ed-subject" name="subject_id" defaultValue={o.subject_id ?? ""}>{(subjects ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
                <label className="field" htmlFor="ed-level">المرحلة<select id="ed-level" name="level_id" defaultValue={o.level_id ?? ""}>{(levels ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
                {(type === "private" || type === "group") && (
                  <label className="field" htmlFor="ed-place">
                    المكان
                    <select id="ed-place" name="place" defaultValue={placeNow}>
                      <option value="home">حضوري</option>
                      <option value="online">أونلاين</option>
                      {type === "private" && <option value="both">الاثنان</option>}
                    </select>
                  </label>
                )}
                {(type === "group" || type === "course") && (
                  <label className="field" htmlFor="ed-seats">عدد المقاعد<input id="ed-seats" name="seats" type="number" min={1} defaultValue={o.seats ?? ""} /></label>
                )}
                {type === "recorded" && (
                  <label className="field" htmlFor="ed-lessons">عدد الدروس<input id="ed-lessons" name="lessons" type="number" min={1} defaultValue={o.lessons_count ?? ""} /></label>
                )}
                {type === "course" && (
                  <label className="field" htmlFor="ed-teacher">
                    المعلم
                    <select id="ed-teacher" name="teacher_id" defaultValue={o.course_teacher_id ?? ""}>
                      <option value="">بدون</option>
                      {(staffList ?? []).map((s: any) => s.teacher && <option key={s.teacher.id} value={s.teacher.id}>{s.teacher.name}</option>)}
                    </select>
                  </label>
                )}
              </div>
              {type === "course" && <label className="row"><input type="checkbox" name="online" defaultChecked={places.includes("online")} /> يمكن الحضور أونلاين أيضاً</label>}
              {type === "private" && (
                <label className="switch-row">
                  <input type="checkbox" name="auto_confirm" defaultChecked={(o as any).auto_confirm} />
                  <span><b>تأكيد فوري</b><span className="small muted">يُثبَّت الحجز مباشرة دون انتظار موافقتك.</span></span>
                </label>
              )}
              {(type === "private" || type === "group") && (
                <label className="switch-row">
                  <input type="checkbox" name="allow_weekly" defaultChecked={(o as any).allow_weekly} />
                  <span><b>السماح بالحجز الأسبوعي</b><span className="small muted">{type === "group" ? "اشتراك في كل اللقاءات القادمة." : "نفس الموعد كل أسبوع، يتجدد تلقائياً."}</span></span>
                </label>
              )}
              <OfferExtras type={type} trialPrice={(o as any).trial_price} packageOn={(o as any).package_enabled} packageSize={(o as any).package_size} packagePrice={(o as any).package_price} />
              <p className="note"><Icon name="check" />من حجز قبل التعديل يبقى على السعر الذي حجز به.</p>
              <button className="btn">حفظ التعديلات</button>
            </form>
          </details>
        </section>
      )}

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

      {type !== "recorded" && <WaitlistOwner rows={(wl ?? []) as WRow[]} back={path} showTitle={false} canAnswer={!!owner} flash={sp.wl} />}

      {((pk ?? []) as any[]).length > 0 && (
        <section className="section">
          <h2>رزم الحصص</h2>
          {((pk ?? []) as { id: string; student_name: string; size: number; remaining: number; price: number; pay_method: string; status: string; created_at: string; pay_status: string }[]).map((p) => (
            <div key={p.id} className="card" style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
              <div className="stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
                <b>{p.student_name}</b>
                <span className="small muted">بقي {p.remaining} من {p.size} · {p.price} ₪ · {PAY_LABEL[p.pay_method] ?? p.pay_method} · {dayLong(p.created_at)}</span>
              </div>
              <div className="stack" style={{ gap: 4, alignItems: "flex-end" }}>
                <span className={`badge ${p.status === "active" ? "ok" : p.status === "cancelled" ? "bad" : ""}`}>{p.status === "active" ? "فعّالة" : p.status === "used" ? "انتهت" : "ملغاة"}</span>
                {p.status !== "cancelled" && <PayBadge status={p.pay_status} method={p.pay_method} teacherView />}
                {owner && p.status !== "cancelled" && <ConfirmPay packageId={p.id} status={p.pay_status} back={path} />}
                {owner && p.status === "active" && (
                  <details>
                    <summary className="link small" style={{ color: "var(--bad)" }}>إلغاء</summary>
                    <form action={cancelPackageAction} style={{ marginTop: 6 }}>
                      <input type="hidden" name="id" value={p.id} />
                      <input type="hidden" name="back" value={path} />
                      <button className="btn sm badb">تأكيد إلغاء الرزمة</button>
                    </form>
                  </details>
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
                {b.series_id ? " · أسبوعي" : ""}
              </span>
            </div>
            <div className="stack" style={{ gap: 4, alignItems: "flex-end" }}>
              <span className={`badge ${b.status === "confirmed" ? "ok" : ""}`}>{b.status === "confirmed" ? "مؤكد" : "بانتظار ردّك"}</span>
              {b.status === "confirmed" && b.pay_status && <PayBadge status={b.pay_status} method={b.pay_method} teacherView />}
              {owner && b.status === "confirmed" && <ConfirmPay bookingId={b.booking_id} status={b.pay_status} back={path} />}
              {owner && (
                <form action={startBookingConversationAction}>
                  <input type="hidden" name="booking_id" value={b.booking_id} />
                  <button className="link small"><Icon name="chat" /> راسل</button>
                </form>
              )}
            </div>
          </div>
        ))}
      </section>
    </div>
  );
}
