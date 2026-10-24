import Link from "next/link";
import { Icon } from "@/components/Icon";
import { requireUser } from "@/lib/session";
import { dayLong } from "@/lib/format";
import { LEVELS } from "@/lib/types";
import { Meter, type ReportRow } from "@/components/Meter";

export const dynamic = "force-dynamic";

/** The parent's lesson reports: newest first, by child, with a simple progress line. */
export default async function Reports({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase } = await requireUser("/reports");
  const { data } = await supabase.rpc("my_reports", { p_child: null, p_limit: 200 });
  const all = (data ?? []) as ReportRow[];
  const people = Array.from(new Map(all.map((r) => [r.child_id ?? "self", r.child_name ?? "أنا"])).entries());
  const who = sp.who && people.some(([k]) => k === sp.who) ? sp.who : null;
  const list = who ? all.filter((r) => (r.child_id ?? "self") === who) : all;

  // Progress per subject: average understanding of the last 5 reports vs the 5 before.
  const bySubject = new Map<string, ReportRow[]>();
  list.forEach((r) => { if (r.understanding) bySubject.set(r.title, [...(bySubject.get(r.title) ?? []), r]); });
  const avg = (xs: ReportRow[]) => (xs.length ? xs.reduce((a, r) => a + (r.understanding ?? 0), 0) / xs.length : 0);
  const progress = Array.from(bySubject.entries()).map(([title, rs]) => {
    const now = avg(rs.slice(0, 5));
    const before = avg(rs.slice(5, 10));
    return { title, now, trend: rs.length > 5 ? now - before : 0, count: rs.length };
  });

  return (
    <div className="wrap">
      <div className="section">
        <h1>تقارير الحصص</h1>
        <p className="small muted">بعد كل حصة يكتب المعلم ماذا تعلّم الطالب، والواجب، ومستوى الفهم والمشاركة.</p>
        {people.length > 1 && (
          <div className="filters">
            <Link className="chip" aria-pressed={!who} href="/reports">الكل</Link>
            {people.map(([k, name]) => <Link key={k} className="chip" aria-pressed={who === k} href={`/reports?who=${k}`}>{name}</Link>)}
          </div>
        )}
        {list.length === 0 && (
          <div className="empty">لا تقارير بعد. تصلك هنا وفي الإشعارات بعد أن يكتبها المعلم بعد الحصة.</div>
        )}

        {progress.length > 0 && (
          <div className="card">
            <b>مستوى الفهم مؤخراً</b>
            {progress.map((p) => (
              <div key={p.title} className="row between small">
                <span>{p.title}</span>
                <span className="row" style={{ gap: 8 }}>
                  <Meter value={Math.round(p.now)} />
                  <span className="muted">{LEVELS[Math.round(p.now)]}</span>
                  {p.trend >= 0.5 && <span className="badge ok">في تحسّن</span>}
                  {p.trend <= -0.5 && <span className="badge bad">يحتاج متابعة</span>}
                </span>
              </div>
            ))}
          </div>
        )}

        {list.map((r) => (
          <Link key={r.id} href={`/reports/${r.id}`} className={`card report-card ${r.read_at ? "" : "unread"}`} style={{ color: "inherit", textDecoration: "none" }}>
            <div className="row between">
              <b>{r.title}</b>
              {!r.read_at && <span className="badge ok">جديد</span>}
            </div>
            <span className="small muted">{dayLong(r.lesson_at)} · {r.teacher ? `أ. ${r.teacher}` : ""}{r.child_name ? ` · ${r.child_name}` : ""}</span>
            {!r.present ? (
              <span className="badge bad" style={{ alignSelf: "flex-start" }}>غياب</span>
            ) : (
              <>
                {r.summary && <p className="small">{r.summary}</p>}
                <div className="row small" style={{ gap: 14, flexWrap: "wrap" }}>
                  {r.understanding && <span>الفهم <Meter value={r.understanding} /></span>}
                  {r.participation && <span>المشاركة <Meter value={r.participation} /></span>}
                  {r.homework && <span><Icon name="check" /> يوجد واجب</span>}
                </div>
              </>
            )}
          </Link>
        ))}
      </div>
    </div>
  );
}
