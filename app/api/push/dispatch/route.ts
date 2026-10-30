import { NextResponse, type NextRequest } from "next/server";
import webpush from "web-push";
import { publicClient } from "@/lib/supabase/public";
import { SITE } from "@/lib/site";
import { sendSms, smsConfigured } from "@/lib/sms";

export const dynamic = "force-dynamic";
export const maxDuration = 30;

type Sub = { endpoint: string; keys: { p256dh: string; auth: string } };
type Item = { id: string; kind: string; body: string; link: string | null; email: string | null; phone: string | null; name: string | null; subs: Sub[] };
type Claim = { vapid_public: string | null; vapid_private: string | null; subject: string; items: Item[] };


// Woken by the database (pg_net) when notifications are waiting. The secret is checked
// inside the database; this route only delivers what the database hands over.
export async function POST(request: NextRequest) {
  let secret = "";
  try {
    secret = String((await request.json())?.secret ?? "");
  } catch {}
  if (!secret) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const db = publicClient();
  const { data, error } = await db.rpc("claim_push", { p_secret: secret });
  if (error) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const claim = data as Claim;
  const items = claim.items ?? [];

  let pushed = 0;
  const dead: string[] = [];
  if (claim.vapid_public && claim.vapid_private) {
    webpush.setVapidDetails(claim.subject, claim.vapid_public, claim.vapid_private);
    const jobs = items.flatMap((it) =>
      it.subs.map(async (s) => {
        try {
          await webpush.sendNotification(
            s,
            JSON.stringify({ title: "Classi", body: it.body, url: it.link ?? "/notifications", tag: it.kind.startsWith("reminder") ? `r-${it.id}` : undefined }),
            { TTL: it.kind.startsWith("reminder") ? 3600 : 86400, urgency: it.kind === "reminder_soon" || it.kind === "message" ? "high" : "normal" }
          );
          pushed++;
        } catch (e: any) {
          if (e?.statusCode === 404 || e?.statusCode === 410) dead.push(s.endpoint);
        }
      })
    );
    await Promise.all(jobs);
    if (dead.length) await db.rpc("drop_push_subscriptions", { p_secret: secret, p_endpoints: dead });
  }

  // Day-before reminders also go by email when an email service is configured.
  let emailed = 0;
  const key = process.env.RESEND_API_KEY;
  const from = process.env.REMINDER_FROM_EMAIL ?? process.env.ALERT_FROM_EMAIL;
  if (key && from) {
    await Promise.all(
      items
        .filter((it) => it.email)
        .map(async (it) => {
          const r = await fetch("https://api.resend.com/emails", {
            method: "POST",
            headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
            body: JSON.stringify({
              from: `Classi <${from.replace(/^.*<|>.*$/g, "")}>`,
              to: it.email,
              subject: "تذكير بحصتك القادمة",
              html: `<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;font-size:16px;line-height:1.7;color:#18204A">
<p>${it.name ? `مرحباً ${escapeHtml(it.name)}،` : "مرحباً،"}</p>
<p><b>${escapeHtml(it.body)}</b></p>
<p><a href="${SITE}/schedule" style="background:#1E2F6E;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;display:inline-block">افتح جدولي</a></p>
<p style="color:#5A6080;font-size:13px">لإيقاف رسائل التذكير بالبريد: صفحة الإشعارات في Classi.</p></div>`,
            }),
          });
          if (r.ok) emailed++;
        })
    );
  }

  // Day-before reminders, moved and cancelled lessons also go by SMS (019) to people who allowed it.
  let texted = 0;
  if (smsConfigured()) {
    const log: { id: string; phone: string; ok: boolean; detail: string }[] = [];
    for (const it of items.filter((x) => x.phone)) {
      const res = await sendSms(it.phone!, `Classi: ${it.body}`);
      log.push({ id: it.id, phone: it.phone!, ok: res.ok, detail: res.detail });
      if (res.ok) texted++;
    }
    if (log.length) await db.rpc("log_sms", { p_secret: secret, p_rows: log });
  }

  return NextResponse.json({ ok: true, items: items.length, pushed, removed: dead.length, emailed, texted });
}

function escapeHtml(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}
