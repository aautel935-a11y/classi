import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { safePath } from "@/lib/safe";

// Email confirmation link lands here: open the session, apply the chosen role.
export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const next = url.searchParams.get("next") ?? "/";
  const role = url.searchParams.get("role");
  const safeNext = safePath(next, "/");
  const supabase = await createClient();
  if (code) {
    const { data, error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) {
      // The link was opened in a different browser than the one that asked for it
      // (common with the Gmail app), or it expired.
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) {
        const msg = safeNext === "/account/password"
          ? "افتح رابط إعادة التعيين في نفس المتصفح الذي طلبته منه (مثلاً Chrome)، أو اطلب رابطاً جديداً."
          : "تم تأكيد بريدك. سجّل الدخول الآن بكلمة المرور.";
        return NextResponse.redirect(new URL(`/login?error=${encodeURIComponent(msg)}&next=${encodeURIComponent(safeNext)}`, url.origin));
      }
    }
    if (data?.user && role && ["guardian", "student", "teacher", "institute"].includes(role)) {
      await supabase.from("profiles").update({ roles: [role], active_role: role }).eq("id", data.user.id);
    }
  }
  return NextResponse.redirect(new URL(safeNext, url.origin));
}
