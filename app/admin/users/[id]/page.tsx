import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { adminHideAction, adminMessageAction, adminSetStatusAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { dayLong, time } from "@/lib/format";
import { TYPES, type OfferingType } from "@/lib/types";
import { ErrorNote } from "@/components/ErrorNote";

export const dynamic = "force-dynamic";
const STATUS: Record<string, string> = { active: "فعّال", suspended: "موقوف مؤقتاً", banned: "محظور" };

export default async function AdminUser({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { id } = await params;
  const sp = await searchParams;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const back = `/admin/users/${id}`;
  const { supabase, user, profile } = await requireUser(back);
  if (!profile?.roles?.includes("admin")) notFound();

  const { data: list } = await supabase.rpc("admin_users", { p_search: null });
  const u = ((list ?? []) as any[]).find((x) => x.id === id);
  if (!u) notFound();
  const [{ data: teacher }, { data: inst }, { data: reports }, { data: log }, { count: bookings }] = await Promise.all([
    u.teacher_id ? supabase.from("teachers").select("id,name,verify,moderation_hidden").eq("id", u.teacher_id).maybeSingle() : Promise.resolve({ data: null }),
    u.institute_id ? supabase.from("institutes").select("id,name,verify,moderation_hidden").eq("id", u.institute_id).maybeSingle() : Promise.resolve({ data: null }),
    supabase.from("reports").select("id,reason,details,status,created_at,target_type").or(`target_id.eq.${id}${u.teacher_id ? `,target_id.eq.${u.teacher_id}` : ""}${u.institute_id ? `,target_id.eq.${u.institute_id}` : ""}`).order("created_at", { ascending: false }).limit(20),
    supabase.from("moderation_actions").select("id,action,reason,created_at").eq("target_id", id).order("created_at", { ascending: false }).limit(10),
    supabase.from("bookings").select("id", { count: "exact", head: true }).eq("booked_by", id),
  ]);
  const ownerFilter = [u.teacher_id && `teacher_id.eq.${u.teacher_id}`, u.institute_id && `institute_id.eq.${u.institute_id}`].filter(Boolean).join(",");
  const { data: offers } = ownerFilter
    ? await supabase.from("offerings").select("id,title,type,active,moderation_hidden").or(ownerFilter).order("created_at")
    : { data: [] as any[] };
  const self = id === user.id;

  const HideBtn = ({ kind, itemId, hidden }: { kind: string; itemId: string; hidden: boolean }) => (
    <form action={adminHideAction}>
      <input type="hidden" name="kind" value={kind} />
      <input type="hidden" name="id" value={itemId} />
      <input type="hidden" name="hidden" value={hidden ? "0" : "1"} />
      <input type="hidden" name="back" value={back} />
      <button className={`btn sm ${hidden ? "okb" : "badb"}`}>{hidden ? "إظهار" : "إخفاء"}</button>
    </form>
  );

  return (
    <div className="wrap">
      <div className="section">
        <Link className="back" href="/admin?tab=users"><Icon name="back" />الحسابات</Link>
        <h1>{u.full_name || "بدون اسم"}</h1>
        <span className="small muted" dir="ltr" style={{ textAlign: "right" }}>{u.email}</span>
        <ErrorNote msg={sp.error} />
        {sp.done && <p className="okmsg">تم.</p>}
        <div className="summary">
          <div><span>الحالة</span><span className={u.status === "active" ? "" : "err-text"}>{STATUS[u.status]}{u.suspended_until && u.status === "suspended" ? ` حتى ${dayLong(u.suspended_until)}` : ""}</span></div>
          <div><span>سجّل</span><span>{dayLong(u.created_at)}</span></div>
          <div><span>آخر دخول</span><span>{u.last_sign_in_at ? `${dayLong(u.last_sign_in_at)} ${time(u.last_sign_in_at)}` : "—"}</span></div>
          <div><span>البلد</span><span>{u.town ?? "—"}</span></div>
          <div><span>حجوزات قام بها</span><span className="num">{bookings ?? 0}</span></div>
          <div><span>بلاغات مفتوحة</span><span className="num">{u.open_reports}</span></div>
        </div>
      </div>

      {!self && (
        <section className="section">
          <h2>رسالة مباشرة</h2>
          {sp.done === "message" && <p className="okmsg">أُرسلت الرسالة: تظهر في إشعاراته وعلى هاتفه.</p>}
          <form action={adminMessageAction} className="card formstack">
            <input type="hidden" name="user_id" value={id} />
            <input type="hidden" name="back" value={back} />
            <textarea name="body" rows={2} maxLength={300} required placeholder="مثلاً: يرجى تحديث جدولك قبل الغد، أو تواصل مع الإدارة بخصوص بلاغ" />
            <p className="small muted">تصله كإشعار في التطبيق وعلى الهاتف، وبرسالة SMS إن وافق على الرسائل.</p>
            <button className="btn sm">إرسال</button>
          </form>
        </section>
      )}

      <section className="section">
        <h2>الحساب</h2>
        {self ? (
          <p className="note">هذا حسابك. لا يمكنك إيقافه.</p>
        ) : (
          <form action={adminSetStatusAction} className="card formstack">
            <input type="hidden" name="user_id" value={id} />
            <input type="hidden" name="back" value={back} />
            <label className="field" htmlFor="reason">السبب (يظهر للمستخدم)<input id="reason" name="reason" placeholder="مثلاً: رسائل مسيئة لأولياء الأمور" /></label>
            <div className="row" style={{ flexWrap: "wrap" }}>
              {u.status !== "active" && <button className="btn sm okb" name="status" value="active">إعادة التفعيل</button>}
              <button className="btn sm ghost" name="status" value="suspended" formAction={adminSetStatusAction}>إيقاف مؤقت</button>
              <select name="days" defaultValue="7" aria-label="مدة الإيقاف" style={{ padding: 8, borderRadius: "var(--r-sm)", border: "1px solid var(--line)", background: "var(--card)" }}>
                <option value="3">3 أيام</option>
                <option value="7">7 أيام</option>
                <option value="30">30 يوماً</option>
              </select>
              <button className="btn sm badb" name="status" value="banned">حظر نهائي</button>
            </div>
            <p className="small muted">الإيقاف والحظر يمنعان الدخول والحجز والمراسلة فوراً، ويُخفيان ملف المعلم أو المعهد عن الطلاب.</p>
          </form>
        )}
      </section>

      {(teacher || inst) && (
        <section className="section">
          <h2>الملفات العامة</h2>
          {teacher && (
            <div className="card" style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
              <div className="stack" style={{ gap: 2, flex: 1 }}>
                <Link className="link" href={`/teacher/${teacher.id}`}>ملف المعلم: {teacher.name}</Link>
                <span className="small muted">{teacher.moderation_hidden ? "مخفي من الإدارة" : teacher.verify === "verified" ? "ظاهر للطلاب" : "غير موثّق"}</span>
              </div>
              <HideBtn kind="teacher" itemId={teacher.id} hidden={teacher.moderation_hidden} />
            </div>
          )}
          {inst && (
            <div className="card" style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
              <div className="stack" style={{ gap: 2, flex: 1 }}>
                <Link className="link" href={`/institute/${inst.id}`}>المعهد: {inst.name}</Link>
                <span className="small muted">{inst.moderation_hidden ? "مخفي من الإدارة" : inst.verify === "verified" ? "ظاهر للطلاب" : "غير موثّق"}</span>
              </div>
              <HideBtn kind="institute" itemId={inst.id} hidden={inst.moderation_hidden} />
            </div>
          )}
          {(offers ?? []).map((o: any) => (
            <div key={o.id} className="card" style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
              <div className="stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
                <Link className="link" href={`/offer/${o.id}`}>{o.title}</Link>
                <span className="small muted">{TYPES[o.type as OfferingType].name}{o.moderation_hidden ? " · مخفي من الإدارة" : !o.active ? " · أخفاه صاحبه" : ""}</span>
              </div>
              <HideBtn kind="offering" itemId={o.id} hidden={o.moderation_hidden} />
            </div>
          ))}
        </section>
      )}

      <section className="section">
        <h2>البلاغات</h2>
        {(reports ?? []).length === 0 && <div className="empty">لا بلاغات.</div>}
        {(reports ?? []).map((r: any) => (
          <div key={r.id} className="card">
            <div className="row between"><span className="badge">{r.reason}</span><span className={`badge ${r.status === "open" ? "bad" : "ok"}`}>{r.status === "open" ? "مفتوح" : r.status === "resolved" ? "عولج" : "مرفوض"}</span></div>
            {r.details && <p className="small">«{r.details}»</p>}
            <span className="small muted">{dayLong(r.created_at)}</span>
          </div>
        ))}
        {(log ?? []).length > 0 && (
          <>
            <h2>إجراءات سابقة على الحساب</h2>
            {(log ?? []).map((l: any) => (
              <p key={l.id} className="small"><b>{l.action}</b> · {dayLong(l.created_at)}{l.reason ? ` · ${l.reason}` : ""}</p>
            ))}
          </>
        )}
      </section>
    </div>
  );
}
