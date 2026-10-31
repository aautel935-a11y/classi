import { Fragment } from "react";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Icon } from "@/components/Icon";
import { leaveReviewAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { ErrorNote } from "@/components/ErrorNote";
import { KeepForm } from "@/components/KeepForm";

export const dynamic = "force-dynamic";

/** Rate a teacher/institute after a lesson (one rating per family member, can be updated). */
export default async function ReviewPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const booking = sp.booking && /^[0-9a-f-]{36}$/i.test(sp.booking) ? sp.booking : null;
  if (!booking) notFound();
  const { supabase, user } = await requireUser(`/review?booking=${booking}`);
  const { data: b } = await supabase
    .from("bookings")
    .select("id,child_id,child:children(name),offering:offerings(id,title,teacher_id,institute_id,teacher:teachers!offerings_teacher_id_fkey(name),institute:institutes(name))")
    .eq("id", booking)
    .eq("booked_by", user.id)
    .maybeSingle();
  if (!b) notFound();
  const x = b as any;
  const ownerName = x.offering?.teacher?.name ?? x.offering?.institute?.name ?? "المعلم";
  let q = supabase.from("reviews").select("stars,body").eq("user_id", user.id);
  q = x.offering?.teacher_id ? q.eq("teacher_id", x.offering.teacher_id) : q.eq("institute_id", x.offering?.institute_id);
  q = x.child_id ? q.eq("child_id", x.child_id) : q.is("child_id", null);
  const { data: mine } = await q.maybeSingle();

  if (sp.done) {
    return (
      <div className="wrap">
        <div className="section">
          <h1>شكراً على التقييم!</h1>
          <p className="muted">تقييمك يساعد عائلات أخرى على اختيار المعلم المناسب.</p>
          <div className="row" style={{ gap: 10 }}>
            <Link className="btn" href="/schedule">جدولي</Link>
            <Link className="btn ghost" href={x.offering?.teacher_id ? `/teacher/${x.offering.teacher_id}` : `/institute/${x.offering?.institute_id}`}>صفحة {ownerName}</Link>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="wrap">
      <form id="kf-leaveReview" action={leaveReviewAction} className="section formstack">
            <KeepForm formId="kf-leaveReview" />
        <Link className="back" href="/schedule"><Icon name="back" />جدولي</Link>
        <h1>كيف كانت الحصة مع {ownerName}؟</h1>
        <p className="muted">{x.offering?.title}{x.child?.name ? ` · ${x.child.name}` : ""}</p>
        <ErrorNote msg={sp.error} />
        {mine && <p className="note"><Icon name="check" />قيّمت هذا المعلم من قبل. التقييم الجديد يحلّ مكان السابق.</p>}
        <input type="hidden" name="booking_id" value={booking} />
        <fieldset className="rating">
          <legend>التقييم</legend>
          <div className="star-pick">
            {[5, 4, 3, 2, 1].map((n) => (
              <Fragment key={n}>
                <input type="radio" id={`s${n}`} name="stars" value={n} required defaultChecked={mine?.stars === n} />
                <label htmlFor={`s${n}`} aria-label={`${n} من 5`}>★</label>
              </Fragment>
            ))}
          </div>
        </fieldset>
        <label className="field">
          كلمة عن التجربة (اختياري، تظهر في صفحة المعلم)
          <textarea name="body" rows={3} maxLength={600} defaultValue={mine?.body ?? ""} placeholder="مثلاً: يشرح بصبر، وابني تحسّن في الامتحان" />
        </label>
        <p className="small muted">يظهر اسمك الأول فقط مع التقييم.</p>
        <button className="btn block">إرسال التقييم</button>
      </form>
    </div>
  );
}
