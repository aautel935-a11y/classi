import { NextResponse, type NextRequest } from "next/server";
import { runHealthChecks } from "@/lib/health";
import { publicClient } from "@/lib/supabase/public";

export const dynamic = "force-dynamic";

// Called by Vercel every morning (vercel.json). When something fails, the admin gets an email.
export async function GET(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (secret && request.headers.get("authorization") !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  // Keep weekly bookings filled for the coming weeks.
  const { data: extended } = await publicClient().rpc("extend_recurring");
  const result = await runHealthChecks();
  let emailed = false;
  const resend = process.env.RESEND_API_KEY;
  const to = process.env.ADMIN_EMAIL;
  const from = process.env.ALERT_FROM_EMAIL;
  if (!result.ok && resend && to && from) {
    const failed = result.checks.filter((c) => c.status === "fail");
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resend}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from,
        to,
        subject: "Classi: خلل في النظام",
        html: `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif"><h2>تنبيه من فحص Classi اليومي</h2><ul>${failed
          .map((c) => `<li><b>${c.label}</b>: ${c.detail}</li>`)
          .join("")}</ul><p>افتح لوحة الإدارة، قسم «حالة النظام»، للتفاصيل.</p></div>`,
      }),
    });
    emailed = r.ok;
  }
  return NextResponse.json({ ok: result.ok, emailed, extended, checks: result.checks }, { status: result.ok ? 200 : 503 });
}
