import Link from "next/link";
import { Avatar } from "@/components/Avatar";
import { adminVerifyAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { dayLong } from "@/lib/format";

export const dynamic = "force-dynamic";

export default async function Admin({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase, profile } = await requireUser("/admin");
  if (!profile?.roles?.includes("admin")) {
    return (
      <div className="wrap"><div className="empty stack"><h1>هذه الصفحة للمدير فقط</h1><Link className="btn" href="/">الرئيسية</Link></div></div>
    );
  }
  const [{ data: teachers }, { data: institutes }, { count: users }, { count: bookings }] = await Promise.all([
    supabase.from("teachers").select("id,name,town,bio,years,is_school_teacher,photo_url,created_at,verify,subject:subjects(name)").neq("verify", "verified").order("created_at"),
    supabase.from("institutes").select("id,name,town,bio,logo_url,created_at,verify").neq("verify", "verified").order("created_at"),
    supabase.from("profiles").select("id", { count: "exact", head: true }),
    supabase.from("bookings").select("id", { count: "exact", head: true }),
  ]);
  const Buttons = ({ kind, id }: { kind: string; id: string }) => (
    <div className="row">
      <form action={adminVerifyAction}><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /><input type="hidden" name="status" value="verified" /><button className="btn sm okb">توثيق</button></form>
      <form action={adminVerifyAction}><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /><input type="hidden" name="status" value="rejected" /><button className="btn sm badb">رفض</button></form>
    </div>
  );
  return (
    <div className="wrap">
      <div className="section">
        <h1>لوحة الإدارة</h1>
        {sp.error && <p className="err">{sp.error}</p>}
        <div className="stats">
          <div className="stat hl"><b className="num">{(teachers ?? []).length + (institutes ?? []).length}</b><span>بانتظار التوثيق</span></div>
          <div className="stat"><b className="num">{users ?? 0}</b><span>حسابات</span></div>
          <div className="stat"><b className="num">{bookings ?? 0}</b><span>حجوزات</span></div>
        </div>
        <p className="note">قبل التوثيق: تأكد من الهوية والشهادات، وإذن العمل مع القاصرين لمن يدرّس طلاباً تحت 18.</p>
      </div>
      <section className="section">
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
      </section>
      <section className="section">
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
    </div>
  );
}
