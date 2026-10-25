import Link from "next/link";
import { Avatar } from "@/components/Avatar";
import { Icon, Stars } from "@/components/Icon";
import { OfferCard } from "@/components/OfferCard";
import { loadCatalog } from "@/lib/catalog";
import { getSession } from "@/lib/session";
import { TYPES, subjectLook, type OfferingType } from "@/lib/types";

export const dynamic = "force-dynamic";

export default async function Home({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { profile } = await getSession();
  const town = profile?.town || "باقة الغربية";
  const { offerings, taken, subjects, teachers: allTeachers } = await loadCatalog();
  const teachers = allTeachers.filter((t) => t.town === town).slice(0, 8);
  const courses = offerings.filter((o) => o.type === "course").slice(0, 3);
  const types: OfferingType[] = ["private", "group", "course", "recorded"];
  const first = profile?.full_name?.split(" ")[0];

  return (
    <div className="wrap">
      {sp.deleted && <p className="okmsg">حُذف حسابك وبياناتك. نتمنى أن نراك مجدداً.</p>}
      <section className="board" aria-labelledby="hero-title">
        <span className="eq" aria-hidden="true">a² + b² = c²</span>
        <h1 id="hero-title">{first ? `أهلاً ${first}، ماذا نتعلّم اليوم؟` : "ماذا نتعلّم اليوم؟"}</h1>
        <p>معلمون خصوصيون، مجموعات تقوية، ودورات معاهد في بلدك وأونلاين.</p>
        <Link className="searchbar" href="/search">
          <Icon name="search" />
          <span>ابحث عن مادة، معلم، أو معهد</span>
        </Link>
      </section>

      <section className="section">
        <h2>المواد</h2>
        <div className="subjects">
          {subjects.map((s) => {
            const look = subjectLook(s.name);
            return (
              <Link key={s.id} className="subj" href={`/search?subject=${s.id}`} style={{ ["--ink" as string]: look.ink, ["--tint" as string]: look.tint }}>
                <span className="g" aria-hidden="true">{look.glyph}</span>
                {s.name}
              </Link>
            );
          })}
        </div>
      </section>

      <section className="section">
        <h2>طريقة التعلّم</h2>
        <div className="types">
          {types.map((k) => (
            <Link key={k} className="type" href={`/search?type=${k}`}>
              <span className="ico"><Icon name={TYPES[k].icon} /></span>
              <b>{TYPES[k].name}</b>
              <span>{TYPES[k].desc}</span>
            </Link>
          ))}
          <Link className="type wide" href="/search?place=online">
            <span className="ico"><Icon name="monitor" /></span>
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
            <Link className="back" href={`/search?town=${encodeURIComponent(town)}`}>الكل</Link>
          </div>
          <div className="hscroll">
            {teachers.map((t: any) => (
              <Link key={t.id} className="card tcard" href={`/teacher/${t.id}`}>
                <Avatar name={t.name} url={t.photo_url} />
                <b style={{ fontFamily: "var(--display)", fontWeight: 600 }}>{t.name}</b>
                <span className="small muted">{t.subject?.name} · {t.town}</span>
                <Stars rating={t.rating} count={t.reviews_count} />
              </Link>
            ))}
          </div>
        </section>
      )}

      {(!profile || profile.active_role === "guardian" || profile.active_role === "student") && (
        <section className="section">
          <div className="card join">
            <h2>معلم أو صاحب معهد؟</h2>
            <p className="small">أنشئ ملفك مجاناً، حدّد أوقاتك وأسعارك، واستقبل الحجوزات. للدروس الحضورية أو عبر زوم.</p>
            <Link className="btn" href={profile ? "/account" : "/login?mode=up&next=/teach"}>{profile ? "حوّل حسابك لمعلم أو معهد" : "انضم إلى Classi"}</Link>
          </div>
        </section>
      )}

      {courses.length > 0 && (
        <section className="section">
          <h2>دورات تبدأ قريباً</h2>
          <div className="stack">
            {courses.map((o) => <OfferCard key={o.id} o={o} taken={taken.get(o.id) ?? 0} />)}
          </div>
        </section>
      )}
    </div>
  );
}
