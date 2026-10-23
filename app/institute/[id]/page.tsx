import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { OfferCard } from "@/components/OfferCard";
import { createClient } from "@/lib/supabase/server";
import { OFFERING_SELECT, type Offering } from "@/lib/types";
import { Avatar } from "@/components/Avatar";

export const dynamic = "force-dynamic";

export default async function InstitutePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const [{ data: ins }, { data: offers }, { count: staff }, { data: seats }] = await Promise.all([
    supabase.from("institutes").select("id,name,town,bio,rating,reviews_count,verify,logo_url").eq("id", id).maybeSingle(),
    supabase.from("offerings").select(OFFERING_SELECT).eq("institute_id", id).eq("active", true),
    supabase.from("institute_teachers").select("teacher_id", { count: "exact", head: true }).eq("institute_id", id),
    supabase.rpc("seats_overview"),
  ]);
  if (!ins) notFound();
  const list = (offers ?? []) as unknown as Offering[];
  const taken = (oid: string) =>
    ((seats ?? []) as { offering_id: string; session_id: string | null; taken: number }[]).filter((r) => r.offering_id === oid && !r.session_id).reduce((a, r) => a + r.taken, 0);
  return (
    <div className="wrap">
      <div className="profile-head">
        <Avatar name={ins.name} url={ins.logo_url} size="lg" inst />
        <div className="stack" style={{ gap: 4, minWidth: 0 }}>
          <h1 style={{ fontSize: 22 }}>{ins.name}</h1>
          <div className="row" style={{ flexWrap: "wrap" }}>
            {ins.verify === "verified" && <span className="badge"><Icon name="shield" />معهد موثّق</span>}
            <span className="badge"><Icon name="pin" />{ins.town}</span>
          </div>
        </div>
      </div>
      <div className="facts">
        <div className="fact"><b className="num">{Number(ins.rating).toFixed(1)}</b><span>التقييم</span></div>
        <div className="fact"><b className="num">{staff ?? 0}</b><span>معلمين</span></div>
        <div className="fact"><b className="num">{list.length}</b><span>دورات</span></div>
      </div>
      {ins.bio && (
        <section className="section">
          <h2>عن المعهد</h2>
          <p>{ins.bio}</p>
        </section>
      )}
      <section className="section">
        <h2>الدورات</h2>
        <div className="stack">
          {list.length ? list.map((o) => <OfferCard key={o.id} o={o} taken={taken(o.id)} showOwner={false} />) : <p className="empty">لا دورات منشورة بعد.</p>}
        </div>
      </section>
    </div>
  );
}
