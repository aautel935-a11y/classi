import { LEDGER_NOTICE, STATUS_LABEL, money, type MyChargeRow } from "@/lib/ledger";

const dmy = (d: string | null) => (d ? d.slice(0, 10).split("-").reverse().join("/") : "");

/** Customer: what businesses recorded as owed and paid (read only), with the notice that Classi does not confirm money. */
export function MyCharges({ rows }: { rows: MyChargeRow[] }) {
  if (rows.length === 0) return null;
  return (
    <section className="section" id="charges">
      <h2>مستحقاتي</h2>
      <p className="note small">{LEDGER_NOTICE}</p>
      {rows.map((r) => (
        <div key={r.id} className="card">
          <div className="row between"><b>{r.business_name}</b><b className="num">{money(r.amount)}</b></div>
          <span className="small muted">{r.description}{r.due_on ? ` · يُستحق ${dmy(r.due_on)}` : ""}</span>
          <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
            <span className={r.status === "paid" ? "badge ok" : r.status === "overdue" ? "badge bad" : "badge"}>{STATUS_LABEL[r.status]}</span>
            {r.status !== "cancelled" && <span className="small num">مدفوع {money(r.paid)} · متبقٍ {money(r.remaining)}</span>}
          </div>
        </div>
      ))}
    </section>
  );
}
