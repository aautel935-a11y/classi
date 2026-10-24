import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { MessageButton } from "@/components/MessageButton";
import { Meter, type ReportRow } from "@/components/Meter";
import { requireUser } from "@/lib/session";
import { dayLong, time } from "@/lib/format";
import { LEVELS } from "@/lib/types";

export const dynamic = "force-dynamic";

export default async function Report({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const { supabase } = await requireUser(`/reports/${id}`);
  const { data } = await supabase.rpc("my_reports", { p_child: null, p_limit: 200 });
  const r = ((data ?? []) as ReportRow[]).find((x) => x.id === id);
  if (!r) notFound();
  const [{ data: o }] = await Promise.all([
    supabase.from("offerings").select("teacher_id,institute_id,course_teacher_id").eq("id", r.offering_id).maybeSingle(),
    r.read_at ? Promise.resolve(null) : supabase.rpc("mark_report_read", { p_report: id }),
  ]);
  const teacherId = (o as any)?.course_teacher_id ?? (o as any)?.teacher_id;

  return (
    <div className="wrap">
      <div className="section">
        <Link className="back" href="/reports"><Icon name="back" />كل التقارير</Link>
        <h1>{r.title}</h1>
        <p className="muted">
          {dayLong(r.lesson_at)} · <span className="num">{time(r.lesson_at)}</span>
          {r.teacher ? ` · أ. ${r.teacher}` : ""}{r.child_name ? ` · ${r.child_name}` : ""}
        </p>
        {!r.present ? (
          <div className="card"><span className="badge bad" style={{ alignSelf: "flex-start" }}>غياب</span><span className="small">سجّل المعلم أن الطالب لم يحضر هذه الحصة.</span></div>
        ) : (
          <>
            {r.summary && (
              <div className="card">
                <b>ماذا تعلّمنا</b>
                <p>{r.summary}</p>
              </div>
            )}
            {r.homework && (
              <div className="card homework">
                <b><Icon name="check" /> الواجب</b>
                <p>{r.homework}</p>
              </div>
            )}
            {(r.understanding || r.participation) && (
              <div className="card">
                {r.understanding && <div className="row between"><span>مستوى الفهم</span><span className="row" style={{ gap: 8 }}><Meter value={r.understanding} /><b>{LEVELS[r.understanding]}</b></span></div>}
                {r.participation && <div className="row between"><span>المشاركة والتركيز</span><span className="row" style={{ gap: 8 }}><Meter value={r.participation} /><b>{LEVELS[r.participation]}</b></span></div>}
              </div>
            )}
          </>
        )}
        {r.note && (
          <div className="card">
            <b>ملاحظة المعلم</b>
            <p>{r.note}</p>
          </div>
        )}
        {teacherId ? (
          <MessageButton teacherId={teacherId} back={`/reports/${id}`} label="راسل المعلم بخصوص التقرير" />
        ) : (o as any)?.institute_id ? (
          <MessageButton instituteId={(o as any).institute_id} back={`/reports/${id}`} label="راسل المعهد" />
        ) : null}
      </div>
    </div>
  );
}
