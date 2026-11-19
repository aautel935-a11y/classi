import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { safePath } from "@/lib/safe";

// Links in Classi's emails (sign-up confirmation, password reset) land here.
// They carry a one-time token instead of relying on a cookie, so they work even
// when the email is opened in another browser or inside the Gmail app.
export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const token_hash = url.searchParams.get("token_hash");
  // only the link types Classi sends; anything else is treated as no link at all
  const TYPES = ["signup", "email", "recovery", "invite", "magiclink", "email_change"] as const;
  const rawType = url.searchParams.get("type");
  const type = (TYPES as readonly string[]).includes(rawType ?? "") ? (rawType as (typeof TYPES)[number]) : null;
  const fallback = type === "recovery" ? "/account/password" : "/";
  const next = url.searchParams.get("next") ?? fallback;
  const safeNext = safePath(next, fallback);

  if (token_hash && /^[A-Za-z0-9_-]{8,512}$/.test(token_hash) && type) {
    const supabase = await createClient();
    const { error } = await supabase.auth.verifyOtp({ type, token_hash });
    if (!error) return NextResponse.redirect(new URL(type === "recovery" ? "/account/password" : safeNext, url.origin));
    return NextResponse.redirect(new URL(`/login?error=${encodeURIComponent("الرابط منتهي أو استُعمل من قبل. اطلب رابطاً جديداً.")}`, url.origin));
  }
  return NextResponse.redirect(new URL("/login", url.origin));
}
