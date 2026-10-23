import Link from "next/link";
import { Icon, Stars } from "@/components/Icon";
import { OfferCard } from "@/components/OfferCard";
import { loadCatalog } from "@/lib/catalog";
import { createClient } from "@/lib/supabase/server";
import { getSession } from "@/lib/session";
import { TYPES, type OfferingType } from "@/lib/types";
import { initials } from "@/lib/format";

export const dynamic = "force-dynamic";

export default async function Home() {
  const { profile } = await getSession();
  const supabase = await createClient();
  const town = profile?.town || "باقة الغربية";
  const [{ offerings, taken }, { data: teachers }] = await Promise.all([
    loadCatalog(),
    supabase.from("teachers").select("id,name,town,rating,reviews_count,subject:subjects(name)").eq("town", town).order("rating", { ascending: false }).limit(8),
  ]);
  const courses = offerings.filter((o) => o.type === "course").slice(0, 3);
  const types: OfferingType[] = ["private", "group", "course", "recorded"];

  return (
    <div className="wrap">
      <div className="hello stack">
        <h1>{profile?.full_name ? `مرحباً ${profile.full_name.split(" ")[0]}، عن ماذا تبحث؟` : "عن ماذا تبحث اليوم؟"}</h1>
        <Link className="searchbar" href="/search">
          <Icon name="search" />
          <span>مادة، معلم، أو معهد</span>
        </Link>
      </div>

      <section className="section">
        <h2>اختر نوع التعليم</h2>
        <div className="types">
          {types.map((k) => (
            <Link key={k} className="type" href={`/search?type=${k}`}>
              <span className="ico">
                <Icon name={TYPES[k].icon} />
              </span>
              <b>{TYPES[k].name}</b>
              <span>{TYPES[k].desc}</span>
            </Link>
          ))}
          <Link className="type wide" href="/search?place=online">
            <span className="ico">
              <Icon name="monitor" />
            </span>
            <div className="stack" style={{ gap: 2 }}>
              <b>أونلاين مباشر</b>
              <span>دروس ومجموعات ودورات من البيت، والرابط يصلك عند التأكيد</span>
            </div>
          </Link>
        </div>
      </section>

      {teachers && teachers.length > 0 && (
        <section className="section">
          <div className="row between">
            <h2>معلمون في {town}</h2>
            <Link className="back" href={`/search?town=${encodeURIComponent(town)}`}>
              الكل
            </Link>
          </div>
          <div className="hscroll">
            {teachers.map((t: any) => (
              <Link key={t.id} className="card tcard" href={`/teacher/${t.id}`}>
                <div className="avatar">{initials(t.name)}</div>
                <b style={{ fontFamily: "var(--display)", fontWeight: 600 }}>{t.name}</b>
                <span className="small muted">
                  {t.subject?.name} · {t.town}
                </span>
                <Stars rating={t.rating} count={t.reviews_count} />
              </Link>
            ))}
          </div>
        </section>
      )}

      {courses.length > 0 && (
        <section className="section">
          <h2>دورات تبدأ قريباً</h2>
          <div className="stack">
            {courses.map((o) => (
              <OfferCard key={o.id} o={o} taken={taken.get(o.id) ?? 0} />
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
