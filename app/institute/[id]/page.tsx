import { instituteMeta } from "@/lib/meta";
import { ReviewsList, type ReviewRow } from "@/components/ReviewsList";
import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { OfferCard } from "@/components/OfferCard";
import { getSession } from "@/lib/session";
import { ReportButton } from "@/components/ReportButton";
import { AdminQuick } from "@/components/AdminQuick";
import { OFFERING_SELECT, type Offering } from "@/lib/types";
import { Avatar } from "@/components/Avatar";
import { MessageButton } from "@/components/MessageButton";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }) {
  return instituteMeta((await params).id);
}

export default async function InstitutePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { id } = await params;
  const sp = await searchParams;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const { supabase, user, profile } = await getSession();
  const isAdmin = !!profile?.roles?.includes("admin");
  const [{ data: ins }, { data: offers }, { count: staff }, { data: seats }, { data: revs }] = await Promise.all([
    supabase.from("institutes").select("id,owner_id,name,town,bio,rating,reviews_count,verify,logo_url,moderation_hidden").eq("id", id).maybeSingle(),
    supabase.from("offerings").select(OFFERING_SELECT).eq("institute_id", id).eq("active", true),
    supabase.from("institute_teachers").select("teacher_id", { count: "exact", head: true }).eq("institute_id", id),
    supabase.rpc("seats_overview"),
    supabase.from("reviews").select("id,stars,body,author_name,reply,created_at").eq("institute_id", id).order("created_at", { ascending: false }).limit(20),
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
      {isAdmin && <AdminQuick kind="institute" id={ins.id} hidden={ins.moderation_hidden} back={`/institute/${ins.id}`} userId={ins.owner_id} />}
      {ins.owner_id && ins.owner_id !== user?.id && <MessageButton instituteId={ins.id} back={`/institute/${ins.id}`} label="راسل المعهد" />}
      <div className="facts" style={{ marginTop: 12 }}>
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
        {ins.owner_id !== user?.id && <ReportButton type="institute" id={ins.id} back={`/institute/${ins.id}`} flash={{ ok: sp.reported, error: sp.report_error }} />}
      </section>
      <ReviewsList rows={(revs ?? []) as ReviewRow[]} />
    </div>
  );
}
