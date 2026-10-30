import type { MetadataRoute } from "next";
import { SITE } from "@/lib/site";
import { publicClient } from "@/lib/supabase/public";

export const revalidate = 3600;

/** Public pages for search engines: only what visitors can already see. */
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const db = publicClient();
  const [{ data: t }, { data: i }, { data: o }] = await Promise.all([
    db.from("teachers").select("id"),
    db.from("institutes").select("id"),
    db.from("offerings").select("id").eq("active", true),
  ]);
  const now = new Date();
  return [
    { url: SITE, lastModified: now, changeFrequency: "daily", priority: 1 },
    { url: `${SITE}/search`, lastModified: now, changeFrequency: "daily", priority: 0.8 },
    ...(t ?? []).map((x: { id: string }) => ({ url: `${SITE}/teacher/${x.id}`, lastModified: now, changeFrequency: "weekly" as const, priority: 0.7 })),
    ...(i ?? []).map((x: { id: string }) => ({ url: `${SITE}/institute/${x.id}`, lastModified: now, changeFrequency: "weekly" as const, priority: 0.6 })),
    ...(o ?? []).map((x: { id: string }) => ({ url: `${SITE}/offer/${x.id}`, lastModified: now, changeFrequency: "weekly" as const, priority: 0.6 })),
    { url: `${SITE}/terms`, lastModified: now, changeFrequency: "yearly", priority: 0.2 },
    { url: `${SITE}/privacy`, lastModified: now, changeFrequency: "yearly", priority: 0.2 },
  ];
}
