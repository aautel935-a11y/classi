// Short signed links to private photos (bucket photos-private), made on the server with the viewer's own session:
// the storage policies decide who may sign which file (the owner their own files, the admin waiting photos only).
// A file the viewer may not read simply gets no link. Never cached, never stored.
import { PRIVATE_BUCKET } from "@/lib/photos";

type Signer = { storage: { from: (b: string) => { createSignedUrls: (paths: string[], seconds: number) => Promise<{ data: { path: string | null; signedUrl: string | null; error: string | null }[] | null; error: unknown }> } } };

/** path -> signed link, for the paths the viewer may read. */
export async function signedPhotoUrls(supabase: Signer, paths: (string | null | undefined)[], seconds: number): Promise<Record<string, string>> {
  const list = [...new Set(paths.filter((p): p is string => typeof p === "string" && p.length > 0))];
  if (!list.length) return {};
  const { data, error } = await supabase.storage.from(PRIVATE_BUCKET).createSignedUrls(list, seconds);
  if (error || !data) return {};
  const out: Record<string, string> = {};
  for (const d of data) if (d.path && d.signedUrl && !d.error) out[d.path] = d.signedUrl;
  return out;
}
