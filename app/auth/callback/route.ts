import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Email confirmation link lands here: open the session, apply the chosen role.
export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const next = url.searchParams.get("next") ?? "/";
  const role = url.searchParams.get("role");
  const safeNext = next.startsWith("/") ? next : "/";
  if (code) {
    const supabase = await createClient();
    const { data } = await supabase.auth.exchangeCodeForSession(code);
    if (data.user && role && ["guardian", "student", "teacher", "institute"].includes(role)) {
      await supabase.from("profiles").update({ roles: [role], active_role: role }).eq("id", data.user.id);
    }
  }
  return NextResponse.redirect(new URL(safeNext, url.origin));
}
