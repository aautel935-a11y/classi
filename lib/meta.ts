import type { Metadata } from "next";
import { publicClient } from "@/lib/supabase/public";

const clip = (s: string | null | undefined, n = 160) => (s ?? "").replace(/\s+/g, " ").trim().slice(0, n);

/** Share-card and search metadata for public pages (only what students can already see). */
export async function teacherMeta(id: string): Promise<Metadata> {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return {};
  const { data: t } = await publicClient().from("teachers").select("name,town,bio,photo_url,rating,reviews_count,subject:subjects(name)").eq("id", id).maybeSingle();
  if (!t) return { title: "معلم" };
  const x = t as any;
  const title = `أ. ${x.name}${x.subject?.name ? ` · ${x.subject.name}` : ""}`;
  const description = clip(`${x.subject?.name ? `${x.subject.name} · ` : ""}${x.town}${x.reviews_count ? ` · ★ ${Number(x.rating).toFixed(1)} (${x.reviews_count})` : ""}. ${x.bio ?? ""}`);
  const images = x.photo_url ? [{ url: x.photo_url, alt: x.name }] : [{ url: "/og.png", width: 1200, height: 630 }];
  return { title, description, alternates: { canonical: `/teacher/${id}` }, openGraph: { title, description, images, type: "profile" }, twitter: { card: x.photo_url ? "summary" : "summary_large_image", title, description } };
}

export async function instituteMeta(id: string): Promise<Metadata> {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return {};
  const { data: i } = await publicClient().from("institutes").select("name,town,bio,logo_url").eq("id", id).maybeSingle();
  if (!i) return { title: "معهد" };
  const description = clip(`${i.town}. ${i.bio ?? ""}`);
  const images = i.logo_url ? [{ url: i.logo_url, alt: i.name }] : [{ url: "/og.png", width: 1200, height: 630 }];
  return { title: i.name, description, alternates: { canonical: `/institute/${id}` }, openGraph: { title: i.name, description, images }, twitter: { card: "summary", title: i.name, description } };
}

export async function offerMeta(id: string): Promise<Metadata> {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return {};
  const { data: o } = await publicClient()
    .from("offerings")
    .select("title,price,type,teacher:teachers!offerings_teacher_id_fkey(name,photo_url,town),institute:institutes(name,logo_url,town)")
    .eq("id", id)
    .maybeSingle();
  if (!o) return { title: "عرض" };
  const x = o as any;
  const owner = x.teacher ? `أ. ${x.teacher.name}` : x.institute?.name ?? "";
  const unit = x.type === "private" ? "للحصة" : x.type === "course" ? "للدورة" : x.type === "group" ? "للقاء" : "";
  const description = clip(`${owner} · ${x.teacher?.town ?? x.institute?.town ?? ""} · ${x.price} ₪ ${unit}. احجز في Classi.`);
  const pic = x.teacher?.photo_url ?? x.institute?.logo_url;
  const images = pic ? [{ url: pic, alt: owner }] : [{ url: "/og.png", width: 1200, height: 630 }];
  return { title: x.title, description, alternates: { canonical: `/offer/${id}` }, openGraph: { title: x.title, description, images }, twitter: { card: pic ? "summary" : "summary_large_image", title: x.title, description } };
}
