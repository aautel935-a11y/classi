import { createClient } from "@/lib/supabase/server";
import Link from "next/link";
import { Avatar } from "@/components/Avatar";
import { Icon } from "@/components/Icon";
import { adminCloseReportAction, adminHideAction, adminSetStatusAction, adminVerifyAction, resolveReportAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { dayLong, time } from "@/lib/format";
import { runHealthChecks } from "@/lib/health";

export const dynamic = "force-dynamic";

const TABS: [string, string][] = [["reports", "البلاغات"], ["verify", "التوثيق"], ["users", "الحسابات"], ["log", "سجلّ الإجراءات"], ["health", "حالة النظام"]];
const REASON: Record<string, string> = {
  no_show: "لم يحضر / ألغى متأخراً", inappropriate: "تصرّف غير لائق", safety: "أمان", fake: "معلومات غير صحيحة", overcharge: "سعر مختلف", other: "سبب آخر",
};
const KIND: Record<string, string> = { teacher: "معلم", institute: "معهد", offering: "عرض", user: "حساب" };
const STATUS: Record<string, string> = { active: "فعّال", suspended: "موقوف مؤقتاً", banned: "محظور" };

export default async function Admin({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const tab = sp.tab ?? "reports";
  const { supabase, profile } = await requireUser("/admin");
  if (!profile?.roles?.includes("admin")) {
    return <div className="wrap"><div className="empty stack"><h1>هذه الصفحة للمدير فقط</h1><Link className="btn" href="/">الرئيسية</Link></div></div>;
  }
  const [{ data: reports }, { data: chatReports }, { count: pendingT }, { count: pendingI }] = await Promise.all([
    supabase.rpc("admin_reports"),
    supabase.from("conversation_reports").select("id,conversation_id,reason,created_at").eq("resolved", false).order("created_at"),
    supabase.from("teachers").select("id", { count: "exact", head: true }).eq("verify", "pending"),
    supabase.from("institutes").select("id", { count: "exact", head: true }).eq("verify", "pending"),
  ]);
  const openCount = (reports ?? []).length + (chatReports ?? []).length;
  const back = `/admin?tab=${tab}`;

  return (
    <div className="wrap">
      <div className="section">
        <h1>لوحة الإدارة</h1>
        {sp.error && <p className="err">{sp.error}</p>}
        {sp.done && <p className="okmsg">تم.</p>}
        <nav className="tabs" aria-label="أقسام الإدارة">
          {TABS.map(([k, l]) => (
            <Link key={k} href={`/admin?tab=${k}`} aria-current={tab === k ? "page" : undefined}>
              {l}
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
      <p className="note"><Icon name="shield" />قبل التوثيق: تأكد من الهوية والشهادات، وإذن العمل مع القاصرين لمن يدرّس طلاباً تحت 18.</p>
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
    a === "hide" ? "إخفاء" : a === "show" ? "إظهار" : a.startsWith("suspended") ? `إيقاف ${a.replace("suspended", "").replace("d", " يوم")}` : a === "banned" ? "حظر" : a === "active" ? "إعادة تفعيل" : a === "resolved" ? "إغلاق بلاغ" : a === "dismissed" ? "رفض بلاغ" : a;
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
