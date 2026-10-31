import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { safePath } from "@/lib/safe";
import { SITE } from "@/lib/site";

// Opening one notification marks that one as read, then goes where it points (phase 3, decision 4:
// a notification counts as read when it is actually opened, not when the list is shown).
export async function GET(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const origin = new URL(request.url).origin || SITE;
  if (!/^[0-9a-f-]{36}$/i.test(id)) return NextResponse.redirect(new URL("/notifications", origin));
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.redirect(new URL(`/login?next=/notifications`, origin));
  const { data: n } = await supabase.from("notifications").select("link").eq("id", id).maybeSingle();
  await supabase.from("notifications").update({ read_at: new Date().toISOString() }).eq("id", id).is("read_at", null);
  return NextResponse.redirect(new URL(safePath(n?.link, "/notifications"), origin));
}
