import { adminSubscriptionAction } from "@/app/actions";
import { adminAccessAction } from "@/app/admin/access-actions";

type Row = { kind: "teacher" | "institute"; business_id: string; name: string; has_account: boolean; state: string; ends_at: string | null;
  days_left: number | null; trial_ends_at: string | null; paid_until: string | null; repeat_trial: boolean; exempt_until: string | null };
type Report = { states: Record<string, number>; recorded_revenue: number; granted_free: number; repeat_trials: number;
  by_month: { month: string; total: number; count: number; discounts: number }[]; notice: string };

const STATE: Record<string, string> = { prelaunch: "قبل الإطلاق", trial: "تجربة مجانية", active: "مشترك", grace: "فترة سماح", expired: "منتهٍ (مخفي)", exempt: "معفى" };
const ORDER = ["grace", "trial", "expired", "active", "exempt", "prelaunch"];
const dmy = (d: string | null) => (d ? new Date(d).toLocaleDateString("en-GB", { timeZone: "Asia/Jerusalem" }) : "—");

/** Admin: trial and grace settings, launch date, every business's access state, extensions, exemptions, report. */
export async function AccessAdmin({ supabase, set }: { supabase: any; set: (k: string) => string }) {
  const from = new Date(Date.now() - 365 * 864e5).toLocaleDateString("en-CA", { timeZone: "Asia/Jerusalem" });
  const to = new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Jerusalem" });
  const [{ data: rowsData }, { data: report }] = await Promise.all([
    supabase.rpc("admin_business_access"),
    supabase.rpc("admin_access_report", { p_from: from, p_to: to }),
  ]);
  const rows = ((rowsData ?? []) as Row[]).filter((r) => r.has_account)
    .sort((a, b) => ORDER.indexOf(a.state) - ORDER.indexOf(b.state) || (a.days_left ?? 999) - (b.days_left ?? 999));
  const r = report as Report | null;
  return (
    <>
      <h2 id="access">التجربة المجانية والوصول</h2>
      <div className="card formstack">
        <p className="small muted">كل نشاط جديد يحصل على فترة تجربة من يوم إنشائه بعد الإطلاق، والأنشطة الموجودة من تاريخ الإطلاق. لا يُحذف شيء عند الانتهاء: يختفي النشاط عن الزبائن فقط، وفقط حين يكون «الاشتراك إلزامي» مفعّلاً.</p>
        {([
          ["trial_days", "أيام التجربة المجانية", "30", "0–90", "number"],
          ["grace_days", "أيام السماح بعد الانتهاء", "7", "0–60", "number"],
          ["launch_at", "تاريخ الإطلاق (يبدأ منه عدّ التجربة للأنشطة الموجودة)", "", "يُقفل بعد أول تجربة جديدة", "date"],
        ] as const).map(([key, label, def, range, type]) => (
          <form key={key} action={adminSubscriptionAction} className="row" style={{ flexWrap: "wrap", gap: 8 }}>
            <input type="hidden" name="op" value="setting" /><input type="hidden" name="key" value={key} />
            <label className="field" style={{ flex: 1, minWidth: 220 }}>{label}
              <input name="value" type={type} dir="ltr" defaultValue={set(key) || def} />
              <span className="small muted">{def ? `الافتراضي ${def} · ` : ""}{range}</span></label>
            <button className="btn sm" style={{ alignSelf: "flex-end" }}>حفظ</button>
          </form>
        ))}
      </div>

      {r && (
        <div className="card">
          <b>آخر 12 شهراً</b>
          <span className="small">{Object.entries(r.states).map(([s, n]) => `${STATE[s] ?? s}: ${n}`).join(" · ") || "لا أنشطة بحساب"}</span>
          <span className="small">إيرادات اشتراكات مسجلة: {r.recorded_revenue} ₪ · اشتراكات مجانية ممنوحة: {r.granted_free} · تجارب مكررة: {r.repeat_trials}</span>
          {r.by_month.length > 0 && <span className="small muted">{r.by_month.map((m) => `${m.month}: ${m.total} ₪ (${m.count}${m.discounts ? `، خصم ${m.discounts} ₪` : ""})`).join(" · ")}</span>}
          <span className="small muted">{r.notice}</span>
        </div>
      )}

      {rows.length === 0 && <div className="empty">لا أنشطة موثّقة بحسابات بعد.</div>}
      {rows.map((x) => (
        <div key={`${x.kind}${x.business_id}`} className="card">
          <div className="row between" style={{ flexWrap: "wrap", gap: 6 }}>
            <b>{x.name} <span className="small muted">({x.kind === "teacher" ? "معلم" : "معهد"})</span></b>
            <span className={x.state === "expired" ? "badge bad" : x.state === "active" || x.state === "exempt" ? "badge ok" : "badge"}>
              {STATE[x.state] ?? x.state}{x.days_left !== null ? ` · ${x.days_left} يوم` : ""}
            </span>
          </div>
          <span className="small muted">التجربة حتى {dmy(x.trial_ends_at)} · مدفوع حتى {dmy(x.paid_until)}{x.exempt_until ? ` · معفى حتى ${dmy(x.exempt_until)}` : ""}</span>
          {x.repeat_trial && <span className="small" style={{ color: "var(--bad)" }}>تجربة مكررة: نفس صاحب الحساب أو نفس الهاتف استعمل تجربة سابقاً. تحقق قبل التمديد.</span>}
          <details>
            <summary className="small">تمديد التجربة أو إعفاء</summary>
            <form action={adminAccessAction} className="row" style={{ flexWrap: "wrap", gap: 8 }}>
              <input type="hidden" name="op" value="extend" /><input type="hidden" name="kind" value={x.kind} /><input type="hidden" name="business_id" value={x.business_id} />
              <label className="field" style={{ width: 90 }}>أيام<input name="days" type="number" min={1} max={90} defaultValue={14} /></label>
              <label className="field" style={{ flex: 1, minWidth: 160 }}>السبب<input name="reason" required minLength={3} /></label>
              <button className="btn sm ghost" style={{ alignSelf: "flex-end" }}>تمديد</button>
            </form>
            <form action={adminAccessAction} className="row" style={{ flexWrap: "wrap", gap: 8 }}>
              <input type="hidden" name="op" value="exempt" /><input type="hidden" name="kind" value={x.kind} /><input type="hidden" name="business_id" value={x.business_id} />
              <label className="field" style={{ width: 160 }}>إعفاء حتى (فارغ = إلغاء)<input name="until" type="date" /></label>
              <label className="field" style={{ flex: 1, minWidth: 160 }}>السبب<input name="reason" required minLength={3} /></label>
              <button className="btn sm ghost" style={{ alignSelf: "flex-end" }}>حفظ الإعفاء</button>
            </form>
          </details>
        </div>
      ))}
    </>
  );
}
