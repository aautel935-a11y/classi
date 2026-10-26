import { NextResponse, type NextRequest } from "next/server";
import { publicClient } from "@/lib/supabase/public";
import { sendSms } from "@/lib/sms";

export const dynamic = "force-dynamic";
export const maxDuration = 20;

// Woken by the database (send_sms_hook → pg_net) when a sign-in code is waiting.
// The secret is checked inside the database; codes are deleted as they are handed over.
export async function POST(request: NextRequest) {
  let secret = "";
  try {
    secret = String((await request.json())?.secret ?? "");
  } catch {}
  if (!secret) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const db = publicClient();
  const { data, error } = await db.rpc("claim_otp", { p_secret: secret });
  if (error) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const items = (data ?? []) as { phone: string; body: string }[];
  // Sign-in codes must really go out, even if test mode is on for reminders.
  const results = await Promise.all(items.map((it) => sendSms(it.phone, it.body, false).then((r) => ({ phone: it.phone, ...r }))));
  if (results.length) {
    await db.rpc("log_sms", {
      p_secret: secret,
      p_rows: results.map((r) => ({ id: "", phone: r.phone, ok: r.ok, detail: `otp · ${r.detail}` })),
    });
  }
  return NextResponse.json({ sent: results.filter((r) => r.ok).length, failed: results.filter((r) => !r.ok).length });
}
