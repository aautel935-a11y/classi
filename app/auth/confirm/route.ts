import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Links in Classi's emails (sign-up confirmation, password reset) land here.
// They carry a one-time token instead of relying on a cookie, so they work even
// when the email is opened in another browser or inside the Gmail app.
export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const token_hash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type") as "signup" | "email" | "recovery" | "invite" | "magiclink" | "email_change" | null;
  const fallback = type === "recovery" ? "/account/password" : "/";
  const next = url.searchParams.get("next") ?? fallback;
  const safeNext = next.startsWith("/") && !next.startsWith("//") ? next : fallback;

  if (token_hash && type) {
    const supabase = await createClient();
    const { error } = await supabase.auth.verifyOtp({ type, token_hash });
    if (!error) return NextResponse.redirect(new URL(type === "recovery" ? "/account/password" : safeNext, url.origin));
    return NextResponse.redirect(new URL(`/login?error=${encodeURIComponent("الرابط منتهي أو استُعمل من قبل. اطلب رابطاً جديداً.")}`, url.origin));
  }
  return NextResponse.redirect(new URL("/login", url.origin));
}
