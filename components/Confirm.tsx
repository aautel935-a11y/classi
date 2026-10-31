// A two-step button for actions that cannot be undone casually (UX-01 / UX-19): the first tap opens a short
// explanation and the real button. Works without JavaScript (<details>), so it is safe in server components.

type Act = (fd: FormData) => void | Promise<void>;

export function Confirm({ action, label, confirm, note, fields, asButton = false, tone = "bad" }: {
  action: Act; label: string; confirm: string; note?: string; fields: Record<string, string>; asButton?: boolean; tone?: "bad" | "neutral";
}) {
  // The key changes with the action's values, so after a toggle (hide -> show) the box starts closed again
  // instead of showing the reverse action ready to tap.
  return (
    <details className="confirm" key={JSON.stringify(fields) + label}>
      <summary className={asButton ? `btn sm ${tone === "bad" ? "badb" : ""}` : "link small"} style={!asButton && tone === "bad" ? { color: "var(--bad)" } : undefined}>
        {label}
      </summary>
      <form action={action} className="confirm-box">
        {Object.entries(fields).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
        {note && <p className="small muted">{note}</p>}
        <button className={`btn sm ${tone === "bad" ? "badb" : ""}`}>{confirm}</button>
      </form>
    </details>
  );
}
