import Link from "next/link";
import { Icon } from "@/components/Icon";
import { OfferCard } from "@/components/OfferCard";
import { deleteOfferingAction, respondAction, startBookingConversationAction, saveAvailabilityAction, teacherSetupAction, toggleOfferingAction, updateTeacherAction } from "@/app/actions";
import { PhotoUpload } from "@/components/PhotoUpload";
import { PushToggle } from "@/components/PushToggle";
import { SubscriptionBox, type Plan, type SubRequest } from "@/components/SubscriptionBox";
import { ReviewsList, type ReviewRow } from "@/components/ReviewsList";
import { PaymentsOwner, type MoneySummary, type PayRow } from "@/components/PaymentsOwner";
import { WaitlistOwner, type WRow } from "@/components/WaitlistOwner";
import { requireUser } from "@/lib/session";
import { OFFERING_SELECT, TOWNS, type Offering } from "@/lib/types";
import { ShareProfile } from "@/components/ShareProfile";
import { SITE } from "@/lib/site";
import { dayLong, isoDay, time } from "@/lib/format";

export const dynamic = "force-dynamic";

type BRow = { booking_id: string; offering_id: string; offering_title: string; offering_type: string; student_name: string; starts_at: string | null; status: string; pay_method: string; mode: string | null; weekly: boolean; series_id: string | null; series_count: number | null };
const DAYS = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];
const modeLabel = (m: string | null) => (m === "online" ? "أونلاين" : m === "home" ? "حضوري" : m === "center" ? "في المعهد" : "");

export default async function Teach({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase, user, profile } = await requireUser("/teach");
  const { data: t } = await supabase.from("teachers").select("id,name,verify,town,bio,years,is_school_teacher,subject_id,photo_url,buffer_minutes,intro_video_url,pending_changes,review_note,whatsapp").eq("user_id", user.id).maybeSingle();

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

  const [{ data: bookings }, { data: offers }, { data: courseSessions }, { data: subjectList }, { data: hours }, { data: links }, { data: wl }, { data: pend }, { data: pays }, { data: money }, { data: bitRow }, { data: reviewRows }, { data: plans }, { data: subReq }, { data: paid }, { data: settings }, { data: myReviews }] = await Promise.all([
    supabase.rpc("owner_bookings"),
    supabase.from("offerings").select(OFFERING_SELECT).eq("teacher_id", t.id).order("created_at"),
    supabase
      .from("sessions")
      .select("id,seq,starts_at,changed,offering_id,room:rooms(name),offering:offerings!inner(title,course_teacher_id,institute:institutes(name))")
      .eq("offering.course_teacher_id", t.id)
      .gt("starts_at", new Date().toISOString())
      .order("starts_at")
      .limit(6),
    supabase.from("subjects").select("id,name").order("id"),
    supabase.from("availability").select("weekday,start_time,end_time").eq("teacher_id", t.id),
    supabase.from("offering_links").select("offering_id"),
    supabase.rpc("owner_waitlist"),
    supabase.rpc("pending_reports"),
    supabase.rpc("owner_payments"),
    supabase.rpc("owner_money_summary"),
    supabase.from("pay_numbers").select("bit_phone").eq("teacher_id", t.id).maybeSingle(),
    supabase.from("offerings").select("id,review_status,review_note,pending_changes").eq("teacher_id", t.id),
    supabase.from("plans").select("code,name,months,price,active").order("sort"),
    supabase.from("subscriptions").select("id,status,price,months").eq("teacher_id", t.id).in("status", ["pending", "reported"]).order("created_at", { ascending: false }).limit(1).maybeSingle(),
    supabase.rpc("paid_until", { p_teacher: t.id, p_institute: null }),
    supabase.from("app_settings").select("key,value"),
    supabase.from("reviews").select("id,stars,body,author_name,reply,created_at").eq("teacher_id", t.id).order("created_at", { ascending: false }).limit(30),
  ]);
  const setting = (k: string) => ((settings ?? []) as { key: string; value: string }[]).find((x) => x.key === k)?.value ?? "";
  const subsRequired = setting("subscriptions_required") === "true";
  const subActive = !!paid && new Date(String(paid)) > new Date();
  const reviewOf = (id: string) => ((reviewRows ?? []) as { id: string; review_status: string; review_note: string | null; pending_changes: unknown }[]).find((r) => r.id === id);
  const bitLocal = bitRow?.bit_phone ? String(bitRow.bit_phone).replace(/^\+972/, "0") : "";
  const hasLink = new Set((links ?? []).map((l) => l.offering_id));
  const dayRanges = (d: number) => ((hours ?? []) as { weekday: number; start_time: string; end_time: string }[])
    .filter((h) => h.weekday === d).sort((x, y) => x.start_time.localeCompare(y.start_time)).map((h) => [h.start_time.slice(0, 5), h.end_time.slice(0, 5)]);
  const rows = (bookings ?? []) as BRow[];
  // One request card per weekly series (its first pending lesson), plus single requests.
  const seenSeries = new Set<string>();
  const requests = rows.filter((b) => {
    if (b.status !== "pending") return false;
    if (!b.series_id) return true;
    if (seenSeries.has(b.series_id)) return false;
    seenSeries.add(b.series_id);
    return true;
  });
  const today = isoDay(new Date());
  const todays = rows.filter((b) => b.status === "confirmed" && b.starts_at && isoDay(b.starts_at) === today);
  const upcoming = rows.filter((b) => b.status === "confirmed" && b.starts_at && b.starts_at > new Date().toISOString()).slice(0, 6);
  const mine = (offers ?? []) as unknown as Offering[];
  const myIds = new Set(mine.map((o) => o.id));
  const waitlist = ((wl ?? []) as WRow[]).filter((w) => myIds.has(w.offering_id));

  return (
    <div className="wrap">
      <div className="section">
        <h1>لوحتي، أ. {t.name.split(" ")[0]}</h1>
        {t.verify !== "verified" && (
          <p className="note"><Icon name="shield" />ملفك بانتظار التوثيق. عروضك تظهر للطلاب بعد التوثيق.</p>
        )}
        {sp.ok && (
          <p className="okmsg">
            {({ profile: "حُفظ ملفك. التعديلات على الاسم والنبذة والصورة والفيديو تظهر للطلاب بعد موافقة الإدارة.", hours: "حُفظت أوقاتك المتاحة.", hidden: "أُخفي العرض. لم يعد يظهر للطلاب.", shown: "العرض ظاهر الآن للطلاب.", deleted: "حُذف العرض.", published: "أُرسل العرض للمراجعة. يظهر للطلاب بعد موافقة الإدارة، ويصلك إشعار.", report: "أُرسل التقرير ووصل ولي الأمر إشعار.", payment: "حُدّثت حالة الدفع.", reply: "حُفظ ردّك على التقييم." } as Record<string, string>)[sp.ok] ?? "تم."}
          </p>
        )}
        {sp.error && <p className="err">{sp.error}</p>}
        <PushToggle compact />
        <div className="stats">
          <div className="stat hl"><b className="num">{todays.length}</b><span>حصص اليوم</span></div>
          <div className="stat"><b className="num">{requests.length}</b><span>طلبات جديدة</span></div>
          {((pays ?? []) as any[]).some((x) => x.pay_status === "reported") && <a className="stat" href="#payments"><b className="num">{((pays ?? []) as any[]).filter((x) => x.pay_status === "reported").length}</b><span>تحويلات للتأكيد</span></a>}
          {((pend ?? []) as any[]).length > 0 && <a className="stat" href="#reports"><b className="num">{(pend as any[]).length}</b><span>تقارير ناقصة</span></a>}
          {waitlist.length > 0 && <a className="stat" href="#waitlist"><b className="num">{waitlist.length}</b><span>في الانتظار</span></a>}
          <div className="stat"><b className="num">{new Set(rows.filter((b) => b.status === "confirmed").map((b) => b.student_name)).size}</b><span>طلاب</span></div>
        </div>
      </div>

      <ShareProfile url={`${SITE}/teacher/${t.id}`} name={`أ. ${t.name}`} />

      <section className="section" id="profile">
        <h2>ملفي</h2>
        {t.pending_changes && <p className="note"><Icon name="clock" />تعديلات ملفك بانتظار موافقة الإدارة. يرى الطلاب النسخة السابقة حتى الموافقة.</p>}
        {!t.pending_changes && t.review_note && <p className="err small">لم تتم الموافقة على آخر تعديل لملفك: {t.review_note}</p>}
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
              <label className="field" htmlFor="e-bit">
                رقم Bit لاستلام الدفعات
                <input id="e-bit" name="bit_phone" type="tel" dir="ltr" inputMode="tel" placeholder="050-1234567" defaultValue={bitLocal} />
                <span className="small muted">يظهر فقط لمن حجز عندك، ليحوّل لك ثمن الحصة.</span>
              </label>
              <label className="field" htmlFor="e-wa">
                رقم واتساب للتواصل (اختياري)
                <input id="e-wa" name="whatsapp" type="tel" dir="ltr" inputMode="tel" placeholder="050-1234567" defaultValue={(t as any).whatsapp ? String((t as any).whatsapp).replace(/^\+972/, "0") : ""} />
                <span className="small muted">يظهر زر «واتساب» في صفحتك ليسألك الأهالي قبل الحجز. اتركه فارغاً لإخفائه.</span>
              </label>
              <label className="field" htmlFor="e-video">
                فيديو تعريفي قصير (اختياري)
                <input id="e-video" name="intro_video" type="url" dir="ltr" placeholder="https://youtu.be/…" defaultValue={t.intro_video_url ?? ""} />
                <span className="small muted">رابط من YouTube أو Instagram أو TikTok أو Google Drive. دقيقة واحدة تعرّف فيها عن نفسك وطريقتك تكفي.</span>
              </label>
              <button className="btn">حفظ</button>
            </form>
          </details>
          <Link className="link small" href={`/teacher/${t.id}`}>كيف يرى الطلاب ملفي</Link>
        </div>
      </section>

      {(() => {
        const steps: [boolean, string, string][] = [
          [!!t.photo_url, "أضف صورة شخصية", "#profile"],
          [(t.bio ?? "").trim().length >= 30, "اكتب نبذة عن أسلوبك (30 حرفاً على الأقل)", "#profile"],
          [(hours ?? []).length > 0, "حدّد أوقاتك المتاحة", "#hours"],
          [!!bitLocal, "أضف رقم Bit لاستلام الدفعات", "#profile"],
          [mine.length > 0, "انشر أول عرض", "/teach/new"],
          [t.verify === "verified", "انتظر توثيق الإدارة لملفك", "#profile"],
          ...(subsRequired ? [[subActive, "فعّل اشتراكاً ليظهر ملفك للطلاب", "#subscription"] as [boolean, string, string]] : []),
        ];
        const done = steps.filter((x) => x[0]).length;
        if (done === steps.length) return null;
        return (
          <section className="section">
            <div className="card">
              <div className="row between"><b>جهّز ملفك للطلاب</b><span className="badge num">{done} من {steps.length}</span></div>
              <div className="seats"><i style={{ width: `${(done / steps.length) * 100}%` }} /></div>
              <div className="checklist">
                {steps.map(([ok, label, href]) => ok
                  ? <span key={label} className="done small"><Icon name="check" />{label}</span>
                  : <Link key={label} className="todo small" href={href}><i />{label}</Link>)}
              </div>
            </div>
          </section>
        );
      })()}

      <Link className="card cal-cta" href="/teach/calendar">
        <span className="row" style={{ gap: 10 }}><Icon name="cal" /><b>جدولي وإدارة الساعات</b></span>
        <span className="small muted">أغلق ساعات، أضف طالباً لساعة فارغة، أو غيّر موعد أي حصة.</span>
      </Link>

      <section className="section">
        <h2>طلبات حجز</h2>
        {requests.length === 0 && <div className="empty">لا طلبات جديدة.</div>}
        {requests.map((r) => (
          <div key={r.booking_id} className="card">
            <div className="row between"><b>{r.student_name}</b>{r.starts_at && <span className="badge num">{time(r.starts_at)}</span>}</div>
            <p className="small">{r.offering_title}</p>
            {r.starts_at && <p className="small muted">{dayLong(r.starts_at)}</p>}
            <div className="row" style={{ flexWrap: "wrap" }}>
              {r.mode && <span className="badge"><Icon name={r.mode === "online" ? "monitor" : "home"} />{modeLabel(r.mode)}</span>}
              {r.series_id && <span className="badge"><Icon name="cal" />أسبوعي · {r.series_count} حصص</span>}
            </div>
            <div className="row">
              <form action={respondAction}><input type="hidden" name="id" value={r.booking_id} /><input type="hidden" name="accept" value="1" /><button className="btn sm okb">{r.series_id ? "قبول كل المواعيد" : "قبول"}</button></form>
              <form action={respondAction}><input type="hidden" name="id" value={r.booking_id} /><input type="hidden" name="accept" value="0" /><button className="btn sm badb">رفض</button></form>
              <form action={startBookingConversationAction}><input type="hidden" name="booking_id" value={r.booking_id} /><button className="btn sm ghost"><Icon name="chat" />راسل</button></form>
            </div>
          </div>
        ))}
      </section>

      {((pend ?? []) as any[]).length > 0 && (
        <section className="section" id="reports">
          <h2>تقارير بانتظارك <span className="badge num">{(pend as any[]).length}</span></h2>
          <p className="small muted">دقيقة واحدة بعد كل حصة: ماذا تعلّم الطالب، الواجب، ومستواه. يصل ولي الأمر فوراً.</p>
          {((pend ?? []) as { booking_id: string | null; session_id: string | null; title: string; who: string | null; lesson_at: string; kind: string; students: number }[]).map((p) => (
            <Link key={p.booking_id ?? p.session_id!} className="card" href={p.booking_id ? `/teach/report?booking=${p.booking_id}` : `/teach/report?session=${p.session_id}`} style={{ flexDirection: "row", alignItems: "center", gap: 12, color: "inherit", textDecoration: "none" }}>
              <div className="stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
                <b>{p.who ?? `${p.title} (${p.students} طلاب)`}</b>
                <span className="small muted">{p.who ? `${p.title} · ` : ""}{dayLong(p.lesson_at)} {time(p.lesson_at)}</span>
              </div>
              <span className="btn sm">اكتب التقرير</span>
            </Link>
          ))}
        </section>
      )}

      <PaymentsOwner rows={(pays ?? []) as PayRow[]} summary={((Array.isArray(money) ? money[0] : money) ?? null) as MoneySummary | null} back="/teach#payments" hasBit={!!bitLocal} />

      <WaitlistOwner rows={waitlist} back="/teach" flash={sp.wl} />

      <section className="section">
        <h2>الحصص القادمة</h2>
        {upcoming.length === 0 && <div className="empty">لا حصص مؤكدة قادمة.</div>}
        {upcoming.map((b) => (
          <Link key={b.booking_id} className="card" href={`/teach/calendar?day=${isoDay(b.starts_at!)}`} style={{ flexDirection: "row", alignItems: "center", gap: 12, color: "inherit", textDecoration: "none" }}>
            <div className="stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
              <b>{b.student_name}{b.series_id ? " · أسبوعي" : ""}</b>
              <span className="small muted">{b.offering_title}{b.mode ? ` · ${modeLabel(b.mode)}` : ""}</span>
            </div>
            <span className="small num">{dayLong(b.starts_at!)} · {time(b.starts_at!)}</span>
          </Link>
        ))}
      </section>

      {(courseSessions ?? []).length > 0 && (
        <section className="section">
          <h2>دوراتي في المعاهد</h2>
          {(courseSessions as any[]).map((s) => (
            <Link key={s.id} className="card" href={`/manage/course/${s.offering_id}`}>
              <div className="row" style={{ flexWrap: "wrap" }}>
                <b>{s.offering.title}، اللقاء {s.seq}</b>
                {s.changed && <span className="badge">غيّر المعهد الموعد</span>}
              </div>
              <span className="small muted">{s.offering.institute?.name} · {dayLong(s.starts_at)} · <span className="num">{time(s.starts_at)}</span>{s.room ? ` · ${s.room.name}` : ""}</span>
              <span className="link small">الطلاب والحضور</span>
            </Link>
          ))}
        </section>
      )}

      <section className="section" id="hours">
        <h2>أوقاتي المتاحة للدروس الخصوصية</h2>
        <form action={saveAvailabilityAction} className="card formstack">
          {sp.ok === "hours" && <p className="okmsg">حُفظت الأوقات.</p>}
          <div className="hours-grid">
            {DAYS.map((d, i) => {
              const r = dayRanges(i);
              return (
                <div key={d} className="hours-day">
                  <label className="row" style={{ gap: 6, minWidth: 92 }}><input type="checkbox" name={`on_${i}`} defaultChecked={r.length > 0} /><b>{d}</b></label>
                  <span className="row" style={{ gap: 4 }}>
                    <input aria-label={`${d} من`} name={`from_${i}`} type="time" defaultValue={r[0]?.[0] ?? "15:00"} />
                    <span className="small muted">حتى</span>
                    <input aria-label={`${d} حتى`} name={`to_${i}`} type="time" defaultValue={r[0]?.[1] ?? "21:00"} />
                  </span>
                  <details open={r.length > 1}>
                    <summary className="link small">فترة ثانية</summary>
                    <span className="row" style={{ gap: 4, marginTop: 4 }}>
                      <input aria-label={`${d} فترة ثانية من`} name={`from2_${i}`} type="time" defaultValue={r[1]?.[0] ?? ""} />
                      <span className="small muted">حتى</span>
                      <input aria-label={`${d} فترة ثانية حتى`} name={`to2_${i}`} type="time" defaultValue={r[1]?.[1] ?? ""} />
                    </span>
                  </details>
                </div>
              );
            })}
          </div>
          <div className="typeform">
            <label className="field" htmlFor="h-buffer">
              استراحة بين الحصص
              <select id="h-buffer" name="buffer" defaultValue={String(t.buffer_minutes ?? 0)}>
                <option value="0">بدون</option>
                <option value="5">5 دقائق</option>
                <option value="10">10 دقائق</option>
                <option value="15">15 دقيقة</option>
                <option value="30">30 دقيقة</option>
              </select>
            </label>
          </div>
          <p className="note"><Icon name="clock" />لكل يوم أوقاته، ويمكن إضافة فترة ثانية (مثلاً صباحاً ومساءً). لعطلة أو إغلاق أيام محددة استخدم <Link className="link" href="/teach/calendar#vacation">التقويم</Link>.</p>
          <button className="btn ghost">حفظ الأوقات</button>
        </form>
      </section>

      <SubscriptionBox required={subsRequired} paidUntil={paid ? String(paid) : null} plans={(plans ?? []) as Plan[]} request={(subReq ?? null) as SubRequest} platformBit={setting("platform_bit")} back="/teach#subscription" flash={sp.sub} hasAccountOffers={mine.length > 0} />

      <ReviewsList rows={(myReviews ?? []) as ReviewRow[]} owner back="/teach#reviews" title="تقييمات العائلات لك" />

      <section className="section">
        <div className="row between">
          <h2>عروضي</h2>
          <Link className="back" href="/teach/new"><Icon name="plus" />عرض جديد</Link>
        </div>
        {mine.length === 0 && <div className="empty">لم تنشر أي عرض بعد. ابدأ بدرس خصوصي.</div>}
        {mine.map((o) => (
          <div key={o.id} className="stack" style={{ gap: 6, opacity: o.active === false ? 0.6 : 1 }}>
            {o.active === false && <span className="badge bad" style={{ alignSelf: "flex-start" }}>مخفي عن الطلاب</span>}
            {reviewOf(o.id)?.review_status === "pending" && <span className="badge warn" style={{ alignSelf: "flex-start" }}>بانتظار موافقة الإدارة، لا يظهر للطلاب بعد</span>}
            {reviewOf(o.id)?.review_status === "rejected" && <span className="badge bad" style={{ alignSelf: "flex-start" }}>مرفوض{reviewOf(o.id)?.review_note ? `: ${reviewOf(o.id)?.review_note}` : ""}. عدّل العرض ليُراجع من جديد.</span>}
            {reviewOf(o.id)?.review_status === "approved" && !!reviewOf(o.id)?.pending_changes && <span className="badge warn" style={{ alignSelf: "flex-start" }}>تعديل بانتظار الموافقة، يظهر بعدها</span>}
            <OfferCard o={o} showOwner={false} />
            {(o.type === "recorded" || o.places.includes("online")) && !hasLink.has(o.id) && (
              <p className="err small">لم تضف رابط {o.type === "recorded" ? "المحتوى" : "زوم"} بعد. الطلاب لن يعرفوا أين يدخلون.</p>
            )}
            <form action={toggleOfferingAction} className="row" style={{ gap: 16 }}>
              <Link className="link small" href={`/manage/course/${o.id}?edit=1`}>تعديل السعر والتفاصيل</Link>
              <Link className="link small" href={`/manage/course/${o.id}`}>إدارة العرض{o.type === "recorded" || o.places.includes("online") ? " والرابط" : ""}</Link>
              <input type="hidden" name="id" value={o.id} />
              <input type="hidden" name="path" value="/teach" />
              <input type="hidden" name="active" value={o.active === false ? "1" : "0"} />
              <button className="link small">{o.active === false ? "إظهار العرض" : "إخفاء العرض"}</button>
            </form>
            <details>
              <summary className="link small" style={{ color: "var(--bad)" }}>حذف العرض نهائياً</summary>
              <form action={deleteOfferingAction} className="row" style={{ marginTop: 8, flexWrap: "wrap" }}>
                <input type="hidden" name="id" value={o.id} />
                <input type="hidden" name="path" value="/teach" />
                <span className="small">متأكد؟ لا يمكن التراجع.</span>
                <button className="btn sm badb">نعم، احذف</button>
              </form>
            </details>
          </div>
        ))}
      </section>
    </div>
  );
}
