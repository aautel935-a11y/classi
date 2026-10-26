import { createClient } from "@/lib/supabase/server";
import Link from "next/link";
import { Avatar } from "@/components/Avatar";
import { Icon } from "@/components/Icon";
import { adminCloseReportAction, adminHideAction, adminHideReviewAction, adminReviewAction, adminSubscriptionAction, adminSetStatusAction, adminVerifyAction, resolveReportAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { dayLong, time } from "@/lib/format";
import { runHealthChecks } from "@/lib/health";
import { OpsTab } from "./OpsTab";

export const dynamic = "force-dynamic";

const TABS: [string, string][] = [["ops", "العمليات"], ["review", "المراجعة"], ["subs", "الاشتراكات والإطلاق"], ["reports", "البلاغات"], ["verify", "التوثيق"], ["users", "الحسابات"], ["log", "سجلّ الإجراءات"], ["health", "حالة النظام"]];
const REASON: Record<string, string> = {
  no_show: "لم يحضر / ألغى متأخراً", inappropriate: "تصرّف غير لائق", safety: "أمان", fake: "معلومات غير صحيحة", overcharge: "سعر مختلف", other: "سبب آخر",
};
const KIND: Record<string, string> = { teacher: "معلم", institute: "معهد", offering: "عرض", user: "حساب", booking: "حجز" };
const STATUS: Record<string, string> = { active: "فعّال", suspended: "موقوف مؤقتاً", banned: "محظور" };

export default async function Admin({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const tab = sp.tab ?? "review";
  const { supabase, profile } = await requireUser("/admin");
  if (!profile?.roles?.includes("admin")) {
    return <div className="wrap"><div className="empty stack"><h1>هذه الصفحة للمدير فقط</h1><Link className="btn" href="/">الرئيسية</Link></div></div>;
  }
  const [{ data: reports }, { data: chatReports }, { count: pendingT }, { count: pendingI }, { data: queue }] = await Promise.all([
    supabase.rpc("admin_reports"),
    supabase.from("conversation_reports").select("id,conversation_id,reason,created_at").eq("resolved", false).order("created_at"),
    supabase.from("teachers").select("id", { count: "exact", head: true }).eq("verify", "pending"),
    supabase.from("institutes").select("id", { count: "exact", head: true }).eq("verify", "pending"),
    supabase.rpc("admin_review_queue"),
  ]);
  const openCount = (reports ?? []).length + (chatReports ?? []).length;
  const back = `/admin?tab=${tab}`;

  return (
    <div className="wrap">
      <div className="section">
        <h1>لوحة الإدارة</h1>
        {sp.error && <p className="err">{sp.error}</p>}
        {sp.done && <p className="okmsg">{sp.done === "cancel" ? "أُلغي الحجز ووصل الطرفين إشعار بالسبب." : sp.done === "payment" ? "حُسمت حالة الدفع ووصل الطرفين إشعار." : sp.done === "message" ? "أُرسلت الرسالة." : "تم."}</p>}
        <nav className="tabs" aria-label="أقسام الإدارة">
          {TABS.map(([k, l]) => (
            <Link key={k} href={`/admin?tab=${k}`} aria-current={tab === k ? "page" : undefined}>
              {l}
              {k === "review" && (queue ?? []).length > 0 ? ` (${(queue ?? []).length})` : ""}
              {k === "reports" && openCount > 0 ? ` (${openCount})` : ""}
              {k === "verify" && (pendingT ?? 0) + (pendingI ?? 0) > 0 ? ` (${(pendingT ?? 0) + (pendingI ?? 0)})` : ""}
            </Link>
          ))}
        </nav>
      </div>

      {tab === "reports" && (
        <section className="section">
          <h2>بلاغات المستخدمين</h2>
          {(reports ?? []).length === 0 && <div className="empty">لا بلاغات مفتوحة.</div>}
          {((reports ?? []) as any[]).map((r) => {
            const href = r.target_type === "teacher" ? `/teacher/${r.target_id}` : r.target_type === "institute" ? `/institute/${r.target_id}` : r.target_type === "offering" ? `/offer/${r.target_id}` : `/admin/users/${r.target_id}`;
            return (
              <div key={r.id} className="card">
                <div className="row between" style={{ flexWrap: "wrap" }}>
                  <span className="badge bad">{REASON[r.reason] ?? r.reason}</span>
                  <span className="small muted">{dayLong(r.created_at)} {time(r.created_at)}</span>
                </div>
                <div className="row" style={{ flexWrap: "wrap" }}>
                  <span className="badge">{KIND[r.target_type]}</span>
                  <Link className="link" href={href}>{r.target_name}</Link>
                  {r.same_target_open > 1 && <span className="badge bad">{r.same_target_open} بلاغات على نفس الهدف</span>}
                </div>
                {r.details && <p className="small">«{r.details}»</p>}
                <span className="small muted">من: {r.reporter_name || "مستخدم"}</span>
                <div className="row" style={{ flexWrap: "wrap" }}>
                  {r.target_type !== "user" && (
                    <form action={adminHideAction}>
                      <input type="hidden" name="kind" value={r.target_type} />
                      <input type="hidden" name="id" value={r.target_id} />
                      <input type="hidden" name="hidden" value="1" />
                      <input type="hidden" name="reason" value={REASON[r.reason] ?? ""} />
                      <input type="hidden" name="back" value={back} />
                      <button className="btn sm badb">إخفاء المحتوى</button>
                    </form>
                  )}
                  {r.owner_id && (
                    <form action={adminSetStatusAction}>
                      <input type="hidden" name="user_id" value={r.owner_id} />
                      <input type="hidden" name="status" value="suspended" />
                      <input type="hidden" name="days" value="7" />
                      <input type="hidden" name="reason" value={REASON[r.reason] ?? ""} />
                      <input type="hidden" name="back" value={back} />
                      <button className="btn sm badb">إيقاف الحساب 7 أيام</button>
                    </form>
                  )}
                  {r.owner_id && <Link className="btn sm ghost" href={`/admin/users/${r.owner_id}`}>الحساب</Link>}
                </div>
                <details>
                  <summary className="link small">إغلاق البلاغ</summary>
                  <form action={adminCloseReportAction} className="formstack" style={{ marginTop: 8 }}>
                    <input type="hidden" name="id" value={r.id} />
                    <label className="field" htmlFor={`note-${r.id}`}>ملاحظة داخلية (اختياري)<input id={`note-${r.id}`} name="note" /></label>
                    <div className="row">
                      <button className="btn sm okb" name="status" value="resolved">تمت المعالجة</button>
                      <button className="btn sm ghost" name="status" value="dismissed">البلاغ غير صحيح</button>
                    </div>
                  </form>
                </details>
              </div>
            );
          })}

          <h2>بلاغات عن محادثات</h2>
          {(chatReports ?? []).length === 0 && <div className="empty">لا بلاغات مفتوحة.</div>}
          {(chatReports ?? []).map((r) => (
            <div key={r.id} className="card">
              <p className="small">{r.reason || "بدون سبب مكتوب"}</p>
              <span className="small muted">{dayLong(r.created_at)}</span>
              <div className="row">
                <Link className="btn sm ghost" href={`/messages/${r.conversation_id}`}>قراءة المحادثة</Link>
                <form action={resolveReportAction}><input type="hidden" name="id" value={r.id} /><button className="btn sm okb">تمت المعالجة</button></form>
              </div>
            </div>
          ))}
        </section>
      )}

      {tab === "ops" && <OpsTab supabase={supabase} q={sp.q ?? ""} />}
      {tab === "review" && <ReviewTab queue={(queue ?? []) as QItem[]} />}
      {tab === "subs" && <SubsTab supabase={supabase} />}
      {tab === "verify" && <VerifyTab supabase={supabase} />}
      {tab === "users" && <UsersTab supabase={supabase} q={sp.q ?? ""} />}
      {tab === "log" && <LogTab supabase={supabase} />}
      {tab === "health" && <HealthTab />}
    </div>
  );
}

async function VerifyTab({ supabase }: { supabase: any }) {
  const [{ data: teachers }, { data: institutes }] = await Promise.all([
    supabase.from("teachers").select("id,name,town,bio,years,is_school_teacher,photo_url,created_at,verify,subject:subjects(name)").neq("verify", "verified").order("created_at"),
    supabase.from("institutes").select("id,name,town,bio,logo_url,created_at,verify").neq("verify", "verified").order("created_at"),
  ]);
  const Buttons = ({ kind, id }: { kind: string; id: string }) => (
    <div className="row">
      <form action={adminVerifyAction}><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /><input type="hidden" name="status" value="verified" /><button className="btn sm okb">توثيق</button></form>
      <form action={adminVerifyAction}><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /><input type="hidden" name="status" value="rejected" /><button className="btn sm badb">رفض</button></form>
    </div>
  );
  return (
    <section className="section">
      <p className="note"><Icon name="shield" />قبل التوثيق: تأكد من الهوية والشهادات وصحة المعلومات في الملف.</p>
      <h2>معلمون</h2>
      {(teachers ?? []).length === 0 && <div className="empty">لا معلمين بانتظار التوثيق.</div>}
      {(teachers ?? []).map((t: any) => (
        <div key={t.id} className="card">
          <div className="row" style={{ gap: 12 }}>
            <Avatar name={t.name} url={t.photo_url} />
            <div className="stack" style={{ gap: 2, minWidth: 0 }}>
              <b>{t.name}</b>
              <span className="small muted">{t.subject?.name ?? "—"} · {t.town} · {t.years} سنوات{t.is_school_teacher ? " · معلم مدرسة" : ""}</span>
            </div>
            {t.verify === "rejected" && <span className="badge bad spacer">مرفوض</span>}
          </div>
          {t.bio && <p className="small">{t.bio}</p>}
          <span className="small muted">سجّل {dayLong(t.created_at)}</span>
          <Buttons kind="teacher" id={t.id} />
        </div>
      ))}
      <h2>معاهد</h2>
      {(institutes ?? []).length === 0 && <div className="empty">لا معاهد بانتظار التوثيق.</div>}
      {(institutes ?? []).map((i: any) => (
        <div key={i.id} className="card">
          <div className="row" style={{ gap: 12 }}>
            <Avatar name={i.name} url={i.logo_url} inst />
            <div className="stack" style={{ gap: 2, minWidth: 0 }}><b>{i.name}</b><span className="small muted">{i.town}</span></div>
            {i.verify === "rejected" && <span className="badge bad spacer">مرفوض</span>}
          </div>
          {i.bio && <p className="small">{i.bio}</p>}
          <Buttons kind="institute" id={i.id} />
        </div>
      ))}
    </section>
  );
}

async function UsersTab({ supabase, q }: { supabase: any; q: string }) {
  const { data: users, error } = await supabase.rpc("admin_users", { p_search: q || null });
  return (
    <section className="section">
      <form className="row" action="/admin">
        <input type="hidden" name="tab" value="users" />
        <input name="q" defaultValue={q} placeholder="اسم، بريد، معلم أو معهد" aria-label="بحث في الحسابات"
          style={{ flex: 1, minWidth: 0, padding: 10, borderRadius: "var(--r-sm)", border: "1px solid var(--line)", background: "var(--card)" }} />
        <button className="btn sm">بحث</button>
      </form>
      {error && <p className="err">{error.message}</p>}
      {(users ?? []).length === 0 && <div className="empty">لا نتائج.</div>}
      {((users ?? []) as any[]).map((u) => (
        <Link key={u.id} href={`/admin/users/${u.id}`} className="card" style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
          <div className="stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
            <b>{u.full_name || "بدون اسم"}</b>
            <span className="small muted" dir="ltr" style={{ textAlign: "right" }}>{u.email}</span>
            <span className="small muted">{[u.teacher_id && "معلم", u.institute_id && "معهد", (u.roles as string[]).includes("admin") && "مدير"].filter(Boolean).join(" · ") || "ولي أمر / طالب"}{u.town ? ` · ${u.town}` : ""}</span>
          </div>
          <div className="stack" style={{ gap: 4, alignItems: "flex-end" }}>
            <span className={`badge ${u.status === "active" ? "ok" : "bad"}`}>{STATUS[u.status]}</span>
            {u.open_reports > 0 && <span className="badge bad">{u.open_reports} بلاغ</span>}
          </div>
        </Link>
      ))}
    </section>
  );
}

async function LogTab({ supabase }: { supabase: any }) {
  const { data } = await supabase.from("moderation_actions").select("id,target_type,target_id,action,reason,created_at").order("created_at", { ascending: false }).limit(60);
  const label = (a: string) =>
    a === "hide" ? "إخفاء" : a === "show" ? "إظهار" : a.startsWith("suspended") ? `إيقاف ${a.replace("suspended", "").replace("d", " يوم")}` : a === "banned" ? "حظر" : a === "active" ? "إعادة تفعيل" : a === "resolved" ? "إغلاق بلاغ" : a === "dismissed" ? "رفض بلاغ" : a === "cancel_booking" ? "إلغاء حجز" : a === "pay_paid" ? "حسم الدفع: مدفوع" : a === "pay_unpaid" ? "حسم الدفع: غير مدفوع" : a === "pay_free" ? "حسم الدفع: مجاني" : a === "message" ? "رسالة مباشرة" : a === "edit_title" ? "تعديل عنوان" : a;
  return (
    <section className="section">
      {(data ?? []).length === 0 && <div className="empty">لا إجراءات بعد.</div>}
      {((data ?? []) as any[]).map((l) => (
        <div key={l.id} className="card" style={{ flexDirection: "row", justifyContent: "space-between", gap: 12 }}>
          <div className="stack" style={{ gap: 2, minWidth: 0 }}>
            <b>{label(l.action)} · {KIND[l.target_type] ?? "بلاغ"}</b>
            {l.reason && <span className="small muted">{l.reason}</span>}
          </div>
          <span className="small muted num">{dayLong(l.created_at)} {time(l.created_at)}</span>
        </div>
      ))}
    </section>
  );
}

async function HealthTab() {
  const [r, { data: smsRows }] = await Promise.all([runHealthChecks(), (await createClient()).rpc("admin_sms_stats")]);
  const sms = (Array.isArray(smsRows) ? smsRows[0] : smsRows) as { sent_month: number; failed_month: number; sent_total: number } | null;
  return (
    <section className="section">
      <p className={r.ok ? "okmsg" : "err"}>{r.ok ? "كل الخدمات تعمل." : "يوجد خلل في خدمة أو أكثر."}</p>
      {r.checks.map((c) => (
        <div key={c.name} className="card" style={{ flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 12 }}>
          <div className="stack" style={{ gap: 2, minWidth: 0 }}>
            <span className={`st ${c.status === "ok" ? "ok" : c.status === "skipped" ? "warn" : "bad"}`}><i />{c.label}</span>
            <span className="small muted">{c.detail}</span>
          </div>
          <span className="small muted num">{c.ms} ms</span>
        </div>
      ))}
      {sms && (
        <div className="card">
          <b>رسائل SMS</b>
          <span className="small">هذا الشهر: <b className="num">{sms.sent_month}</b> رسالة{sms.failed_month ? ` · فشل ${sms.failed_month}` : ""} · المجموع <span className="num">{sms.sent_total}</span></span>
          <span className="small muted">تُرسل فقط: تذكير قبل الحصة بيوم، وتغيير موعد أو إلغاء حصة، لمن أضاف رقمه ووافق.</span>
        </div>
      )}
      <p className="small muted">يُفحص النظام تلقائياً كل صباح، ويصلك بريد إذا تعطّلت خدمة.</p>
    </section>
  );
}

type QItem = { kind: "offering" | "teacher" | "institute"; id: string; owner_name: string; title: string; what: "new" | "edit"; current: Record<string, any>; changes: Record<string, any> | null; created_at: string };

const FIELD: Record<string, string> = {
  title: "العنوان", name: "الاسم", bio: "النبذة", photo_url: "الصورة", logo_url: "الشعار", intro_video_url: "الفيديو التعريفي", town: "البلد",
  years: "سنوات الخبرة", subject_id: "المادة", level_id: "المرحلة", places: "المكان", schedule_note: "الموعد", trial_price: "الحصة التجريبية",
  package_enabled: "رزمة الحصص", package_size: "عدد حصص الرزمة", package_price: "سعر الرزمة", lessons_count: "عدد الدروس", is_school_teacher: "معلم مدرسة",
  sessions_count: "عدد اللقاءات", minutes: "مدة الحصة", type: "النوع", price: "السعر", subject: "المادة", level: "المرحلة",
};
const TYPE_AR: Record<string, string> = { private: "درس خصوصي", group: "مجموعة", course: "دورة معهد", recorded: "محتوى مسجّل" };
const PLACE_AR: Record<string, string> = { home: "حضوري", online: "أونلاين", center: "في المعهد" };

function show(k: string, v: any) {
  if (v === null || v === undefined || v === "") return "—";
  if (k === "photo_url" || k === "logo_url") return <img src={String(v)} alt="" style={{ width: 56, height: 56, borderRadius: 12, objectFit: "cover" }} />;
  if (k === "intro_video_url") return <a className="link" href={String(v)} target="_blank" rel="noopener noreferrer" dir="ltr">{String(v)}</a>;
  if (k === "places" && Array.isArray(v)) return v.map((p) => PLACE_AR[p] ?? p).join("، ");
  if (k === "type") return TYPE_AR[v] ?? v;
  if (typeof v === "boolean") return v ? "نعم" : "لا";
  if (k === "price" || k === "package_price" || k === "trial_price") return `${v} ₪`;
  return String(v);
}

/** Everything teachers and institutes want to publish, waiting for the admin. */
function ReviewTab({ queue }: { queue: QItem[] }) {
  return (
    <section className="section">
      <p className="note"><Icon name="shield" />لا يظهر للطلاب أي عرض جديد، ولا أي تعديل على عرض أو ملف معلم أو معهد، قبل موافقتك هنا.</p>
      {queue.length === 0 && <div className="empty">لا شيء بانتظار المراجعة.</div>}
      {queue.map((q) => (
        <div key={`${q.kind}${q.id}`} className="card">
          <div className="row between">
            <b>{q.title}</b>
            <span className="badge">{q.what === "new" ? "عرض جديد" : q.kind === "offering" ? "تعديل عرض" : q.kind === "teacher" ? "تعديل ملف معلم" : "تعديل ملف معهد"}</span>
          </div>
          <span className="small muted">{q.owner_name} · {dayLong(q.created_at)}</span>
          {q.what === "new" ? (
            <div className="summary">
              {Object.entries(q.current).filter(([, v]) => v !== null && v !== false && v !== "").map(([k, v]) => (
                <div key={k}><span>{FIELD[k] ?? k}</span><span>{show(k, v)}</span></div>
              ))}
            </div>
          ) : (
            <div className="summary">
              {Object.entries(q.changes ?? {}).map(([k, v]) => (
                <div key={k} style={{ alignItems: "flex-start" }}>
                  <span>{FIELD[k] ?? k}</span>
                  <span className="stack" style={{ gap: 4, alignItems: "flex-end" }}>
                    <span className="small muted" style={{ textDecoration: "line-through" }}>{show(k, q.current[k])}</span>
                    <b>{show(k, v)}</b>
                  </span>
                </div>
              ))}
            </div>
          )}
          <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
            <form action={adminReviewAction}>
              <input type="hidden" name="kind" value={q.kind} /><input type="hidden" name="id" value={q.id} /><input type="hidden" name="approve" value="1" />
              <button className="btn sm okb">موافقة ونشر</button>
            </form>
            <details>
              <summary className="link small" style={{ color: "var(--bad)" }}>رفض</summary>
              <form action={adminReviewAction} className="row" style={{ marginTop: 6, flexWrap: "wrap" }}>
                <input type="hidden" name="kind" value={q.kind} /><input type="hidden" name="id" value={q.id} /><input type="hidden" name="approve" value="0" />
                <input className="inline-input" name="note" placeholder="السبب (يصل لصاحب العرض)" maxLength={300} style={{ flex: 1, minWidth: 180 }} />
                <button className="btn sm badb">رفض</button>
              </form>
            </details>
          </div>
        </div>
      ))}
    </section>
  );
}

type SubRow = { kind: string; owner_id: string; owner_name: string; has_account: boolean; paid_until: string | null; request_id: string | null; request_status: string | null; request_price: number | null; request_months: number | null; requested_at: string | null };
const fmtDate = (d: string) => new Date(d).toLocaleDateString("ar-u-nu-latn", { timeZone: "Asia/Jerusalem", day: "numeric", month: "short", year: "numeric" });

/** Subscriptions, launch switches and recent ratings. */
async function SubsTab({ supabase }: { supabase: any }) {
  const [{ data: rows }, { data: settings }, { data: plans }, { data: revs }] = await Promise.all([
    supabase.rpc("admin_subscriptions"),
    supabase.from("app_settings").select("key,value"),
    supabase.from("plans").select("code,name,months,price,active").order("sort"),
    supabase.from("reviews").select("id,stars,body,author_name,hidden,created_at,teacher:teachers(name),institute:institutes(name)").order("created_at", { ascending: false }).limit(20),
  ]);
  const set = (k: string) => ((settings ?? []) as { key: string; value: string }[]).find((x) => x.key === k)?.value ?? "";
  const list = (rows ?? []) as SubRow[];
  const requests = list.filter((r) => r.request_id);
  const owners = list.filter((r) => r.has_account);
  const required = set("subscriptions_required") === "true";
  const demoVisible = set("demo_visible") !== "false";
  const now = new Date().toISOString();
  return (
    <section className="section">
      <h2>الإطلاق</h2>
      <div className="card formstack">
        <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
          <span><b>المعلمون والمعاهد التجريبيون</b><br /><span className="small muted">{demoVisible ? "ظاهرون للطلاب الآن." : "مخفيون عن الطلاب."}</span></span>
          <form action={adminSubscriptionAction}><input type="hidden" name="op" value="demo" /><input type="hidden" name="visible" value={demoVisible ? "0" : "1"} />
            <button className={`btn sm ${demoVisible ? "badb" : ""}`}>{demoVisible ? "إخفاء البيانات التجريبية" : "إظهارها مجدداً"}</button></form>
        </div>
        <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
          <span><b>الاشتراك إلزامي للظهور</b><br /><span className="small muted">{required ? "من لا يملك اشتراكاً فعّالاً لا يظهر للطلاب." : "فترة إطلاق: الجميع يظهر مجاناً."}</span></span>
          <form action={adminSubscriptionAction}><input type="hidden" name="op" value="setting" /><input type="hidden" name="key" value="subscriptions_required" /><input type="hidden" name="value" value={required ? "false" : "true"} />
            <button className="btn sm">{required ? "إيقاف الإلزام" : "تفعيل الإلزام"}</button></form>
        </div>
        <form action={adminSubscriptionAction} className="row" style={{ flexWrap: "wrap", gap: 8 }}>
          <input type="hidden" name="op" value="setting" /><input type="hidden" name="key" value="platform_bit" />
          <label className="field" style={{ flex: 1, minWidth: 200 }}>رقم Bit لاستلام الاشتراكات
            <input name="value" type="tel" dir="ltr" defaultValue={set("platform_bit").replace(/^\+972/, "0")} placeholder="050-1234567" /></label>
          <button className="btn sm" style={{ alignSelf: "flex-end" }}>حفظ</button>
        </form>
      </div>

      <h2>الباقات</h2>
      <div className="plans">
        {((plans ?? []) as { code: string; name: string; months: number; price: number; active: boolean }[]).map((p) => (
          <form key={p.code} action={adminSubscriptionAction} className="plan">
            <input type="hidden" name="op" value="plan" /><input type="hidden" name="code" value={p.code} />
            <b>{p.name}</b>
            <label className="field">السعر (₪)<input name="price" type="number" min={0} defaultValue={p.price} /></label>
            <label className="row small"><input type="checkbox" name="active" defaultChecked={p.active} /> متاحة</label>
            <button className="btn sm ghost">حفظ</button>
          </form>
        ))}
      </div>

      <h2>طلبات بانتظارك {requests.length > 0 && <span className="badge num">{requests.length}</span>}</h2>
      {requests.length === 0 && <div className="empty">لا طلبات اشتراك.</div>}
      {requests.map((r) => (
        <div key={r.request_id!} className="card">
          <div className="row between"><b>{r.owner_name}</b><b className="num">{r.request_price} ₪</b></div>
          <span className="small muted">{r.kind === "teacher" ? "معلم" : "معهد"} · {r.request_months} {r.request_months === 1 ? "شهر" : "أشهر"} · {r.request_status === "reported" ? "يقول إنه حوّل عبر Bit" : "اختار باقة ولم يحوّل بعد"}{r.requested_at ? ` · ${fmtDate(r.requested_at)}` : ""}</span>
          <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
            <form action={adminSubscriptionAction}><input type="hidden" name="op" value="activate" /><input type="hidden" name="id" value={r.request_id!} /><button className="btn sm okb">وصل المبلغ، فعّل</button></form>
            <details><summary className="link small" style={{ color: "var(--bad)" }}>لم يصل</summary>
              <form action={adminSubscriptionAction} className="row" style={{ marginTop: 6, flexWrap: "wrap" }}>
                <input type="hidden" name="op" value="reject" /><input type="hidden" name="id" value={r.request_id!} />
                <input className="inline-input" name="note" placeholder="ملاحظة (اختياري)" style={{ flex: 1, minWidth: 160 }} />
                <button className="btn sm badb">رفض</button>
              </form>
            </details>
          </div>
        </div>
      ))}

      <h2>المشتركون</h2>
      <form action={adminSubscriptionAction} className="card row" style={{ flexWrap: "wrap", gap: 8 }}>
        <input type="hidden" name="op" value="grant" />
        <label className="field" style={{ flex: 2, minWidth: 180 }}>منح أشهر مجانية
          <select name="owner" required>{owners.map((o) => <option key={o.owner_id} value={`${o.kind}:${o.owner_id}`}>{o.owner_name} ({o.kind === "teacher" ? "معلم" : "معهد"})</option>)}</select></label>
        <label className="field" style={{ flex: 1, minWidth: 90 }}>أشهر<input name="months" type="number" min={1} max={36} defaultValue={1} /></label>
        <input className="inline-input" name="note" placeholder="سبب (مثلاً: عرض الإطلاق)" style={{ flex: 2, minWidth: 160 }} />
        <button className="btn sm" style={{ alignSelf: "flex-end" }}>منح</button>
      </form>
      {owners.length === 0 && <div className="empty">لا معلمين أو معاهد بحسابات بعد.</div>}
      {owners.map((o) => {
        const ok = !!o.paid_until && o.paid_until > now;
        return (
          <div key={`${o.kind}${o.owner_id}`} className="card" style={{ flexDirection: "row", justifyContent: "space-between", alignItems: "center", gap: 10 }}>
            <span><b>{o.owner_name}</b> <span className="small muted">{o.kind === "teacher" ? "معلم" : "معهد"}</span></span>
            <span className={`badge ${ok ? "ok" : required ? "bad" : ""}`}>{ok ? `حتى ${fmtDate(o.paid_until!)}` : o.paid_until ? `انتهى ${fmtDate(o.paid_until)}` : "بلا اشتراك"}</span>
          </div>
        );
      })}

      <h2>آخر التقييمات</h2>
      {((revs ?? []) as any[]).length === 0 && <div className="empty">لا تقييمات بعد.</div>}
      {((revs ?? []) as any[]).map((r) => (
        <div key={r.id} className="card" style={{ opacity: r.hidden ? 0.55 : 1 }}>
          <div className="row between"><b>{r.teacher?.name ?? r.institute?.name}</b><span className="review-stars">{"★".repeat(r.stars)}</span></div>
          {r.body && <p className="small">{r.body}</p>}
          <span className="small muted">{r.author_name || "ولي أمر"} · {fmtDate(r.created_at)}{r.hidden ? " · مخفي" : ""}</span>
          <form action={adminHideReviewAction}><input type="hidden" name="id" value={r.id} /><input type="hidden" name="hidden" value={r.hidden ? "0" : "1"} /><input type="hidden" name="back" value="/admin?tab=subs" />
            <button className="link small" style={{ color: r.hidden ? undefined : "var(--bad)" }}>{r.hidden ? "إظهار التقييم" : "إخفاء التقييم (مسيء أو غير صحيح)"}</button></form>
        </div>
      ))}
    </section>
  );
}
