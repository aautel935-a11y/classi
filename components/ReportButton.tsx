import { submitReportAction } from "@/app/actions";

const REASONS: [string, string][] = [
  ["no_show", "لم يحضر أو ألغى في آخر لحظة"],
  ["inappropriate", "كلام أو تصرّف غير لائق"],
  ["safety", "شعرت بعدم الأمان"],
  ["fake", "معلومات أو شهادات غير صحيحة"],
  ["overcharge", "طلب مبلغاً مختلفاً عن المعلن"],
  ["other", "سبب آخر"],
];

/** Small "report" link that opens a short form. Reports go to the admin queue. */
export function ReportButton({ type, id, back, flash }: { type: "teacher" | "institute" | "offering"; id: string; back: string; flash?: { ok?: string; error?: string } }) {
  if (flash?.ok) return <p className="okmsg">وصل بلاغك للإدارة. شكراً، سنراجعه في أقرب وقت.</p>;
  return (
    <details className="report-box">
      <summary className="link small muted">الإبلاغ عن مشكلة</summary>
      <form action={submitReportAction} className="card formstack">
        <input type="hidden" name="target_type" value={type} />
        <input type="hidden" name="target_id" value={id} />
        <input type="hidden" name="back" value={back} />
        <fieldset>
          <legend>ما المشكلة؟</legend>
          {REASONS.map(([k, l], i) => (
            <label key={k} className="radio-opt">
              <input type="radio" name="reason" value={k} defaultChecked={i === 0} />
              {l}
            </label>
          ))}
        </fieldset>
        <label className="field" htmlFor={`details-${id}`}>
          تفاصيل (اختياري)
          <textarea id={`details-${id}`} name="details" rows={3} maxLength={1000} placeholder="ماذا حدث ومتى؟" />
        </label>
        {flash?.error && <p className="err">{flash.error}</p>}
        <button className="btn sm badb">إرسال البلاغ</button>
        <p className="small muted">البلاغ سرّي، لا يرى المعلم أو المعهد من أبلغ.</p>
      </form>
    </details>
  );
}
