import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

// Connection check: shows whether the database answers, without revealing the key.
export async function GET() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";
  const out: Record<string, unknown> = {
    url_host: url.replace(/^https?:\/\//, "").split("/")[0] || null,
    key_kind: key.startsWith("sb_publishable_") ? "publishable" : key.startsWith("eyJ") ? "legacy-anon" : key ? "unknown" : "missing",
    key_length: key.length,
  };
  if (url && key) {
    const supabase = await createClient();
    const { count, error } = await supabase.from("offerings").select("id", { count: "exact", head: true });
    out.offerings = count;
    out.error = error ? { code: error.code, message: error.message } : null;
  }
  return NextResponse.json(out);
}
