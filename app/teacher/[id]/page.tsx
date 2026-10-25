import { teacherMeta } from "@/lib/meta";
import { ReviewsList, type ReviewRow } from "@/components/ReviewsList";
import { IntroVideo } from "@/components/IntroVideo";
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
  return teacherMeta((await params).id);
}

export default async function TeacherPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { id } = await params;
  const sp = await searchParams;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const { supabase, user, profile } = await getSession();
  const isAdmin = !!profile?.roles?.includes("admin");
  const [{ data: t }, { data: offers }, { data: revs }] = await Promise.all([
    supabase.from("teachers").select("id,user_id,name,town,bio,years,is_school_teacher,rating,reviews_count,verify,photo_url,moderation_hidden,intro_video_url,subject:subjects(name)").eq("id", id).maybeSingle(),
    supabase.from("offerings").select(OFFERING_SELECT).eq("teacher_id", id).eq("active", true),
    supabase.from("reviews").select("id,stars,body,author_name,reply,created_at").eq("teacher_id", id).order("created_at", { ascending: false }).limit(20),
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
      {isAdmin && <AdminQuick kind="teacher" id={teacher.id} hidden={teacher.moderation_hidden} back={`/teacher/${teacher.id}`} userId={teacher.user_id} />}
      {teacher.user_id && teacher.user_id !== user?.id && <MessageButton teacherId={teacher.id} back={`/teacher/${teacher.id}`} label="راسل المعلم" />}
      <div className="facts" style={{ marginTop: 12 }}>
        <div className="fact"><b className="num">{Number(teacher.rating).toFixed(1)}</b><span>التقييم</span></div>
        <div className="fact"><b className="num">{teacher.reviews_count}</b><span>تقييماً</span></div>
        <div className="fact"><b className="num">{teacher.years}</b><span>سنوات خبرة</span></div>
      </div>
      {(teacher.bio || teacher.intro_video_url) && (
        <section className="section">
          <h2>عن المعلم</h2>
          {teacher.bio && <p>{teacher.bio}</p>}
          <IntroVideo url={teacher.intro_video_url} name={teacher.name} />
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
        {teacher.user_id !== user?.id && <ReportButton type="teacher" id={teacher.id} back={`/teacher/${teacher.id}`} flash={{ ok: sp.reported, error: sp.report_error }} />}
      </section>
      <ReviewsList rows={(revs ?? []) as ReviewRow[]} />
    </div>
  );
}
