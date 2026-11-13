import { NextResponse, type NextRequest } from "next/server";
import { publicClient } from "@/lib/supabase/public";
import { sendSms } from "@/lib/sms";
import { workerClient } from "@/lib/supabase/worker";
import { codeFromBody } from "@/lib/otp-code";

export const dynamic = "force-dynamic";
export const maxDuration = 20;

type Item = { phone: string; body: string; email: string | null; otp?: string | null };


async function emailCode(to: string, otp: string) {
  const key = process.env.RESEND_API_KEY;
  const from = process.env.REMINDER_FROM_EMAIL ?? process.env.ALERT_FROM_EMAIL;
  if (!key || !from) return false;
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: `Classi <${from.replace(/^.*<|>.*$/g, "")}>`,
      to,
      subject: `${otp} رمز الدخول إلى Classi`,
      html: `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:16px;line-height:1.7;color:#18204A">
<p>لم نتمكن من إرسال الرسالة النصية، فهذا رمزك:</p>
<p style="font-size:32px;letter-spacing:8px;font-weight:bold;direction:ltr;text-align:center">${otp.replace(/\D/g, "")}</p>
<p style="color:#5A6080;font-size:13px">صالح 5 دقائق. لا تشاركه مع أحد. إن لم تطلبه فتجاهل هذه الرسالة.</p></div>`,
    }),
    cache: "no-store",
  });
  return r.ok;
}

// Woken by the database (send_sms_hook → pg_net) when a sign-in code is waiting. Codes are deleted as they are handed over.
// D-08 / TM-13: with SUPABASE_SERVICE_ROLE_KEY the route checks the wake-up secret and claims codes through the worker_*
// functions (service role only); without it, the old anon functions behind the secret (removed by step B).
// TM-14: if 019 cannot deliver it, the same code goes by email only to an email the account has confirmed.
export async function POST(request: NextRequest) {
  let secret = "";
  try {
    secret = String((await request.json())?.secret ?? "");
  } catch {}
  if (!secret) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const w = workerClient();
  const db = publicClient();
  let items: Item[];
  if (w) {
    const ok = await w.rpc("worker_wake_ok", { p_secret: secret });
    if (ok.error || ok.data !== true) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
    const { data, error } = await w.rpc("worker_claim_otp");
    if (error) return NextResponse.json({ error: "unavailable" }, { status: 503 });
    items = (data ?? []) as Item[];
  } else {
    const { data, error } = await db.rpc("claim_otp", { p_secret: secret });
    if (error) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
    items = (data ?? []) as Item[];
  }
  const results = await Promise.all(
    items.map(async (it) => {
      const r = await sendSms(it.phone, it.body, false); // sign-in codes always really go out
      let detail = `otp · ${r.detail}`;
      const code = codeFromBody(it.body);
      if (!r.ok && it.email && code) detail += (await emailCode(it.email, code)) ? " · emailed instead" : " · email failed too";
      return { phone: it.phone, ok: r.ok, detail };
    })
  );
  if (results.length) {
    const rows = results.map((r) => ({ id: "", phone: r.phone, ok: r.ok, detail: r.detail }));
    if (w) await w.rpc("worker_log_sms", { p_rows: rows });
    else await db.rpc("log_sms", { p_secret: secret, p_rows: rows });
  }
  return NextResponse.json({ sent: results.filter((r) => r.ok).length, failed: results.filter((r) => !r.ok).length });
}
