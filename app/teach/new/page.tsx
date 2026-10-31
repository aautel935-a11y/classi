import Link from "next/link";
import { requireUser } from "@/lib/session";
import { NewOfferForm } from "./NewOfferForm";
import { errorText } from "@/lib/safe";

export const dynamic = "force-dynamic";

export default async function NewOffer({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase, user } = await requireUser("/teach/new");
  const [{ data: subjects }, { data: levels }, { data: me }] = await Promise.all([
    supabase.from("subjects").select("id,name").order("id"),
    supabase.from("levels").select("id,name").order("sort"),
    supabase.from("teachers").select("id").eq("user_id", user.id).maybeSingle(),
  ]);
  // No teacher profile yet: ask for it first instead of showing a form that would be thrown away (BUG-08).
  if (!me) {
    return (
      <div className="wrap">
        <div className="section">
          <h1>عرض جديد</h1>
          <p className="note">قبل نشر أول عرض، أكمل ملفك كمعلم (الاسم والمادة والبلدة). يأخذ ذلك دقيقة.</p>
          <Link className="btn" href="/teach">أكمل ملفي</Link>
        </div>
      </div>
    );
  }
  return (
    <div className="wrap">
      <NewOfferForm subjects={subjects ?? []} levels={levels ?? []} error={errorText(sp.error) ?? undefined} />
    </div>
  );
}
