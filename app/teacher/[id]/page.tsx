import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { OfferCard } from "@/components/OfferCard";
import { createClient } from "@/lib/supabase/server";
import { OFFERING_SELECT, type Offering } from "@/lib/types";
import { Avatar } from "@/components/Avatar";

export const dynamic = "force-dynamic";

export default async function TeacherPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const [{ data: t }, { data: offers }] = await Promise.all([
    supabase.from("teachers").select("id,name,town,bio,years,is_school_teacher,rating,reviews_count,verify,photo_url,subject:subjects(name)").eq("id", id).maybeSingle(),
    supabase.from("offerings").select(OFFERING_SELECT).eq("teacher_id", id).eq("active", true),
  ]);
  if (!t) notFound();
  const teacher = t as any;
  return (
    <div className="wrap">
      <div className="profile-head">
        <Avatar name={teacher.name} url={teacher.photo_url} size="lg" />
        <div className="stack" style={{ gap: 4, minWidth: 0 }}>
          <h1 style={{ fontSize: 22 }}>أ. {teacher.name}</h1>
          <div className="row" style={{ flexWrap: "wrap" }}>
            {teacher.verify === "verified" ? (
              <span className="badge"><Icon name="shield" />موثّق</span>
            ) : (
              <span className="badge">بانتظار التوثيق</span>
            )}
            {teacher.is_school_teacher && <span className="badge">معلم مدرسة</span>}
            <span className="badge"><Icon name="pin" />{teacher.town}</span>
          </div>
        </div>
      </div>
      <div className="facts">
        <div className="fact"><b className="num">{Number(teacher.rating).toFixed(1)}</b><span>التقييم</span></div>
        <div className="fact"><b className="num">{teacher.reviews_count}</b><span>تقييماً</span></div>
        <div className="fact"><b className="num">{teacher.years}</b><span>سنوات خبرة</span></div>
      </div>
      {teacher.bio && (
        <section className="section">
          <h2>عن المعلم</h2>
          <p>{teacher.bio}</p>
        </section>
      )}
      <section className="section">
        <h2>ما يقدّمه</h2>
        <div className="stack">
          {(offers as unknown as Offering[] | null)?.length ? (
            (offers as unknown as Offering[]).map((o) => <OfferCard key={o.id} o={o} showOwner={false} />)
          ) : (
            <p className="empty">لا عروض منشورة بعد.</p>
          )}
        </div>
        <p className="note"><Icon name="check" />يقيّم فقط من حضر حصة فعلاً.</p>
      </section>
    </div>
  );
}
