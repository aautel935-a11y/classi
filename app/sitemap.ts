import type { MetadataRoute } from "next";
import { SITE } from "@/lib/site";
import { publicClient } from "@/lib/supabase/public";
import { fetchAll } from "@/lib/fetch-all";

export const revalidate = 3600;

/** Public pages for search engines: only what visitors can already see. */
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const db = publicClient();
  // Read in pages: the API returns at most 1,000 rows per request.
  // If the database cannot be reached (for example during a build without it), the fixed pages are still listed.
  const [t, i, o] = await Promise.all([
    fetchAll<{ id: string }>((a, b) => db.from("teachers").select("id").order("id").range(a, b)),
    fetchAll<{ id: string }>((a, b) => db.from("institutes").select("id").order("id").range(a, b)),
    fetchAll<{ id: string }>((a, b) => db.from("offerings").select("id").eq("active", true).order("id").range(a, b)),
  ]).catch(() => [[], [], []] as { id: string }[][]);
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
