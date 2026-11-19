import Link from "next/link";
import { requireUser } from "@/lib/session";
import { ErrorNote } from "@/components/ErrorNote";
import { Icon } from "@/components/Icon";
import {
  KIND_LABEL, LEDGER_NOTICE, METHOD_LABEL, METHODS, STATUS_LABEL, STATUSES, isStatus, money, totals,
  type ChargeRow, type EntryRow,
} from "@/lib/ledger";
import {
  adjustChargeAction, cancelChargeAction, createChargeAction, recordPaymentAction, staffPermissionAction, voidPaymentAction,
} from "./actions";

export const dynamic = "force-dynamic";
export const metadata = { title: "سجل المستحقات · Classi" };

type Biz = { kind: "teacher" | "institute"; business_id: string; name: string; is_owner: boolean; can_record: boolean; can_correct: boolean; can_reports: boolean };
type Report = { received_total: number; received_by_method: Record<string, number>; open_total: number; open_count: number;
  overdue_0_30: number; overdue_31_60: number; overdue_over_60: number; corrections: number };

const OK: Record<string, string> = {
  charge: "أُضيف المستحق.", payment: "سُجّلت الدفعة.", void: "سُجّل التصحيح، وبقيت الدفعة الأصلية ظاهرة في السجل.",
  adjust: "عُدّل المستحق وسُجّل السبب.", cancel: "أُلغي المستحق وسُجّل السبب.", staff: "حُدّثت صلاحيات الطاقم.",
};
const PERMS: [string, string][] = [["payments.record", "تسجيل الدفعات"], ["payments.correct", "التصحيح والإلغاء"], ["payments.reports", "التقارير"]];
const today = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Jerusalem" });
const daysAgo = (n: number) => new Date(Date.now() - n * 864e5).toLocaleDateString("en-CA", { timeZone: "Asia/Jerusalem" });
const dmy = (d: string | null) => (d ? d.slice(0, 10).split("-").reverse().join("/") : "—");
const badgeClass = (s: string) => (s === "paid" ? "badge ok" : s === "overdue" ? "badge bad" : "badge");

export default async function Ledger({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase } = await requireUser("/ledger");
  const { data: bizData } = await supabase.rpc("my_ledger_businesses");
  const all = ((bizData ?? []) as Biz[]).filter((b) => b.can_record || b.is_owner);
  if (all.length === 0) {
    return (
      <div className="wrap"><div className="section">
        <h1 style={{ fontSize: 22 }}>سجل المستحقات</h1>
        <div className="empty">هذا السجل لأصحاب الأعمال وطاقمهم المخوّل. أنشئ ملف معلم أو معهد أولاً.</div>
      </div></div>
    );
  }
  const biz = all.find((b) => `${b.kind[0]}:${b.business_id}` === sp.b) ?? all[0];
  const bq = `b=${biz.kind[0]}:${biz.business_id}`;
  const owner = { p_teacher: biz.kind === "teacher" ? biz.business_id : null, p_institute: biz.kind === "institute" ? biz.business_id : null };
  const status = isStatus(sp.s) ? sp.s : null;
  const openId = sp.open && /^[0-9a-f-]{36}$/i.test(sp.open) ? sp.open : null;
  const self = (extra = "") => `/ledger?${bq}${status ? `&s=${status}` : ""}${extra}`;

  const [{ data: rowsData }, { data: entriesData }, { data: reportData }, { data: staffData }] = await Promise.all([
    supabase.rpc("business_charges", { ...owner, p_status: null }),
    openId ? supabase.rpc("charge_entries", { p_charge: openId }) : Promise.resolve({ data: [] }),
    biz.is_owner || biz.can_reports
      ? supabase.rpc("ledger_report", { p_from: daysAgo(30), p_to: today(), ...owner })
      : Promise.resolve({ data: null }),
    biz.is_owner && biz.kind === "institute"
      ? supabase.rpc("institute_staff_permissions", { p_institute: biz.business_id })
      : Promise.resolve({ data: [] }),
  ]);
  const rows = (rowsData ?? []) as ChargeRow[];
  const shown = status ? rows.filter((r) => r.status === status) : rows;
  const t = totals(rows);
  const report = reportData as Report | null;
  const entries = (entriesData ?? []) as EntryRow[];
  const staff = (staffData ?? []) as { teacher_id: string; name: string; permissions: string[] }[];

  return (
    <div className="wrap">
      <div className="section">
        <h1 style={{ fontSize: 22 }}>سجل المستحقات</h1>
        <p className="note small"><Icon name="shield" />{LEDGER_NOTICE} الزبون يدفع لك مباشرة بالطريقة التي تتفقان عليها.</p>
        {sp.ok && OK[sp.ok] && <p className="okmsg">{OK[sp.ok]}</p>}
        <ErrorNote msg={sp.error} />

        {all.length > 1 && (
          <nav className="row" style={{ gap: 8, flexWrap: "wrap" }} aria-label="النشاط">
            {all.map((b) => (
              <Link key={b.business_id} className="chip" aria-current={b === biz ? "page" : undefined} href={`/ledger?b=${b.kind[0]}:${b.business_id}`}>
                {b.name}{b.is_owner ? "" : " (طاقم)"}
              </Link>
            ))}
          </nav>
        )}

        <div className="money">
          <div className="stat hl"><b className="num">{money(t.remaining)}</b><span>متبقٍ لك ({t.open})</span></div>
          <div className="stat"><b className="num">{money(t.overdue)}</b><span>متأخر</span></div>
          <div className="stat"><b className="num">{money(report?.received_total ?? t.paid)}</b><span>{report ? "وصلك آخر 30 يوماً" : "مدفوع"}</span></div>
        </div>
        {report && (
          <details className="card">
            <summary><b>تقرير آخر 30 يوماً</b></summary>
            <span className="small">حسب الطريقة: {Object.keys(report.received_by_method).length === 0 ? "لا دفعات" :
              Object.entries(report.received_by_method).map(([m, v]) => `${METHOD_LABEL[m as keyof typeof METHOD_LABEL] ?? m} ${money(v)}`).join(" · ")}</span>
            <span className="small">المتأخر: حتى 30 يوماً {money(report.overdue_0_30)} · 31–60 يوماً {money(report.overdue_31_60)} · أكثر من 60 يوماً {money(report.overdue_over_60)}</span>
            <span className="small muted">تصحيحات في الفترة: {report.corrections}</span>
            <a className="btn sm ghost" href={`/ledger/export?${bq}`} download>تصدير CSV للمحاسب</a>
          </details>
        )}

        <nav className="row" style={{ gap: 6, flexWrap: "wrap" }} aria-label="تصفية">
          <Link className="chip" aria-current={!status ? "page" : undefined} href={`/ledger?${bq}`}>الكل ({rows.length})</Link>
          {STATUSES.map((s) => (
            <Link key={s} className="chip" aria-current={status === s ? "page" : undefined} href={`/ledger?${bq}&s=${s}`}>
              {STATUS_LABEL[s]} ({rows.filter((r) => r.status === s).length})
            </Link>
          ))}
        </nav>

        {biz.can_record && (
          <details className="card" open={rows.length === 0}>
            <summary><b>مستحق جديد</b></summary>
            <form action={createChargeAction} className="col" style={{ gap: 8 }}>
              <input type="hidden" name="back" value={self()} />
              <input type="hidden" name={biz.kind === "teacher" ? "teacher_id" : "institute_id"} value={biz.business_id} />
              <label className="field">الزبون<input name="customer" required maxLength={80} placeholder="الاسم كما تعرفه" /></label>
              <label className="field">الوصف<input name="description" required maxLength={200} placeholder="مثلاً: تبديل قفل، رزمة 5 حصص" /></label>
              <div className="row" style={{ gap: 8 }}>
                <label className="field">المبلغ (₪)<input name="amount" required inputMode="decimal" placeholder="0" /></label>
                <label className="field">العربون (اختياري)<input name="deposit" inputMode="decimal" /></label>
              </div>
              <label className="field">تاريخ الاستحقاق (اختياري)<input name="due_on" type="date" /></label>
              <button className="btn sm">إضافة</button>
            </form>
          </details>
        )}

        {shown.length === 0 && <div className="empty">{status ? "لا مستحقات بهذه الحالة." : "لا مستحقات بعد."}</div>}
        {shown.map((r) => (
          <div key={r.id} className="card" id={`c-${r.id}`}>
            <div className="row between"><b>{r.customer_label}</b><b className="num">{money(r.amount)}</b></div>
            <span className="small muted">{r.description}{r.due_on ? ` · يُستحق ${dmy(r.due_on)}` : ""}</span>
            <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
              <span className={badgeClass(r.status)}>{STATUS_LABEL[r.status]}</span>
              <span className="small num">مدفوع {money(r.paid)} · متبقٍ {money(r.remaining)}</span>
            </div>
            {r.cancel_reason && <span className="small muted">سبب الإلغاء: {r.cancel_reason}</span>}
            {openId === r.id ? (
              <ChargeDetail r={r} entries={entries} biz={biz} back={self(`&open=${r.id}#c-${r.id}`)} close={self(`#c-${r.id}`)} />
            ) : (
              <Link className="btn sm ghost" href={self(`&open=${r.id}#c-${r.id}`)}>الدفعات والتفاصيل</Link>
            )}
          </div>
        ))}

        {staff.length > 0 && (
          <details className="card">
            <summary><b>صلاحيات الطاقم في السجل</b></summary>
            <span className="small muted">التسجيل يسمح بإضافة دفعات وتصحيح دفعة سجّلها الموظف خلال 24 ساعة. التصحيح والإلغاء والتقارير لصاحب المعهد ومن يخوّله.</span>
            {staff.map((s) => (
              <div key={s.teacher_id} className="row between" style={{ flexWrap: "wrap", gap: 6 }}>
                <b>{s.name}</b>
                <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
                  {PERMS.map(([p, label]) => {
                    const on = s.permissions.includes(p);
                    return (
                      <form key={p} action={staffPermissionAction}>
                        <input type="hidden" name="back" value={self()} />
                        <input type="hidden" name="institute_id" value={biz.business_id} />
                        <input type="hidden" name="teacher_id" value={s.teacher_id} />
                        <input type="hidden" name="permission" value={p} />
                        <input type="hidden" name="on" value={on ? "0" : "1"} />
                        <button className="chip" aria-pressed={on}>{label}</button>
                      </form>
                    );
                  })}
                </div>
              </div>
            ))}
          </details>
        )}
      </div>
    </div>
  );
}

function ChargeDetail({ r, entries, biz, back, close }: { r: ChargeRow; entries: EntryRow[]; biz: Biz; back: string; close: string }) {
  const voidedBy = new Map(entries.filter((e) => e.kind === "void" && e.voids).map((e) => [e.voids!, e]));
  return (
    <div className="col" style={{ gap: 8 }}>
      {entries.length === 0 && <span className="small muted">لا دفعات مسجلة بعد.</span>}
      {entries.filter((e) => e.kind !== "void").map((e) => {
        const v = voidedBy.get(e.id);
        return (
          <div key={e.id} className="card" style={{ opacity: e.voided ? 0.6 : 1 }}>
            <div className="row between">
              <span>{KIND_LABEL[e.kind]} · {e.method ? METHOD_LABEL[e.method] : ""} · {dmy(e.paid_on)}</span>
              <b className="num" style={{ textDecoration: e.voided ? "line-through" : undefined }}>{e.kind === "refund" ? "−" : ""}{money(e.amount)}</b>
            </div>
            {e.note && <span className="small muted">{e.note}</span>}
            <span className="small muted">سجّلها {e.recorded_by_name || "—"} في {dmy(e.recorded_at)}</span>
            {v && <span className="small"><Icon name="shield" /> أُلغيت بتصحيح: {v.note} ({v.recorded_by_name || "—"}، {dmy(v.recorded_at)})</span>}
            {!e.voided && r.status !== "cancelled" && (
              <details>
                <summary className="small">تصحيح هذه الدفعة</summary>
                <form action={voidPaymentAction} className="col" style={{ gap: 6 }}>
                  <input type="hidden" name="back" value={back} />
                  <input type="hidden" name="payment_id" value={e.id} />
                  <label className="field">سبب التصحيح<input name="reason" required minLength={3} maxLength={300} /></label>
                  <button className="btn sm badb">إلغاء هذه الدفعة بتصحيح موثق</button>
                </form>
              </details>
            )}
          </div>
        );
      })}

      {r.status !== "cancelled" && biz.can_record && (
        <form action={recordPaymentAction} className="col" style={{ gap: 8 }}>
          <input type="hidden" name="back" value={back} />
          <input type="hidden" name="charge_id" value={r.id} />
          <b>تسجيل دفعة</b>
          <div className="row" style={{ gap: 8 }}>
            <label className="field">النوع
              <select name="kind" defaultValue={r.paid === 0 && r.deposit_amount ? "deposit" : "payment"}>
                <option value="payment">دفعة</option><option value="deposit">عربون</option><option value="refund">استرداد</option>
              </select>
            </label>
            <label className="field">المبلغ (₪)<input name="amount" required inputMode="decimal" defaultValue={r.paid === 0 && r.deposit_amount ? r.deposit_amount : r.remaining || ""} /></label>
          </div>
          <div className="row" style={{ gap: 8 }}>
            <label className="field">الطريقة
              <select name="method" defaultValue="cash">{METHODS.map((m) => <option key={m} value={m}>{METHOD_LABEL[m]}</option>)}</select>
            </label>
            <label className="field">التاريخ<input name="paid_on" type="date" defaultValue={today()} /></label>
          </div>
          <label className="field">ملاحظة (اختياري، بلا أرقام بطاقات أو حسابات)<input name="note" maxLength={300} /></label>
          <label className="small row" style={{ gap: 6 }}><input type="checkbox" name="allow_over" value="1" /> المبلغ أكبر من المتبقي (يلزم توضيح في الملاحظة)</label>
          <button className="btn sm okb">تسجيل</button>
        </form>
      )}

      {r.status !== "cancelled" && biz.can_correct && (
        <details>
          <summary className="small">تعديل المبلغ أو الإلغاء</summary>
          <form action={adjustChargeAction} className="col" style={{ gap: 6 }}>
            <input type="hidden" name="back" value={back} />
            <input type="hidden" name="charge_id" value={r.id} />
            <div className="row" style={{ gap: 8 }}>
              <label className="field">المبلغ الصحيح<input name="amount" required inputMode="decimal" defaultValue={r.amount} /></label>
              <label className="field">الاستحقاق<input name="due_on" type="date" defaultValue={r.due_on ?? ""} /></label>
            </div>
            <label className="field">السبب<input name="reason" maxLength={300} /></label>
            <button className="btn sm ghost">حفظ التعديل</button>
          </form>
          <form action={cancelChargeAction} className="col" style={{ gap: 6 }}>
            <input type="hidden" name="back" value={back} />
            <input type="hidden" name="charge_id" value={r.id} />
            <label className="field">سبب الإلغاء<input name="reason" required minLength={3} maxLength={300} /></label>
            <button className="btn sm badb">إلغاء المستحق</button>
          </form>
        </details>
      )}
      <Link className="small" href={close}>إغلاق التفاصيل</Link>
    </div>
  );
}
