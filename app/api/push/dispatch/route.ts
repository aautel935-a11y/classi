import { NextResponse, type NextRequest } from "next/server";
import webpush from "web-push";
import { publicClient } from "@/lib/supabase/public";
import { SITE } from "@/lib/site";
import { sendSms, smsConfigured } from "@/lib/sms";
import { escapeHtml } from "@/lib/escape";
import { runPool } from "@/lib/pool";
import { workerClient } from "@/lib/supabase/worker";
import { pushPayload } from "@/lib/push-text";

export const dynamic = "force-dynamic";
export const maxDuration = 30;

type Sub = { endpoint: string; keys: { p256dh: string; auth: string } };
type Item = { id: string; kind: string; body: string; link: string | null; email: string | null; phone: string | null; name: string | null; subs: Sub[] };
type Keys = { vapid_public: string | null; vapid_private: string | null; subject: string };

// D-08 / TM-13: with SUPABASE_SERVICE_ROLE_KEY the route uses the worker_* functions (service role only; the secret only
// proves the database woke us). Without it, the old anon functions behind the secret (removed by step B).
type Api = {
  wakeOk: () => Promise<boolean>;
  claim: (limit: number) => Promise<{ items: Item[]; keys: Keys } | null>;
  drop: (endpoints: string[]) => Promise<unknown>;
  log: (rows: unknown[]) => Promise<unknown>;
};

function api(secret: string): Api {
  const w = workerClient();
  if (w) {
    let keys: Keys | null = null;
    return {
      wakeOk: async () => { const { data, error } = await w.rpc("worker_wake_ok", { p_secret: secret }); return !error && data === true; },
      claim: async (limit) => {
        const { data, error } = await w.rpc("worker_claim_push", { p_limit: limit });
        if (error) return null;
        if (!keys) keys = ((await w.rpc("worker_push_keys")).data as Keys | null) ?? { vapid_public: null, vapid_private: null, subject: "" };
        return { items: (data as Item[]) ?? [], keys };
      },
      drop: (endpoints) => w.rpc("worker_drop_push_subscriptions", { p_endpoints: endpoints }) as unknown as Promise<unknown>,
      log: (rows) => w.rpc("worker_log_sms", { p_rows: rows }) as unknown as Promise<unknown>,
    };
  }
  const db = publicClient();
  return {
    wakeOk: async () => true, // the legacy functions check the secret themselves
    claim: async (limit) => {
      const { data, error } = await db.rpc("claim_push", { p_secret: secret, p_limit: limit });
      if (error) return null;
      const c = data as Keys & { items: Item[] };
      return { items: c.items ?? [], keys: c };
    },
    drop: (endpoints) => db.rpc("drop_push_subscriptions", { p_secret: secret, p_endpoints: endpoints }) as unknown as Promise<unknown>,
    log: (rows) => db.rpc("log_sms", { p_secret: secret, p_rows: rows }) as unknown as Promise<unknown>,
  };
}


// Woken by the database (pg_net) when notifications are waiting. The secret is checked
// inside the database; this route only delivers what the database hands over.
export async function POST(request: NextRequest) {
  let secret = "";
  try {
    secret = String((await request.json())?.secret ?? "");
  } catch {}
  if (!secret) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const db = api(secret);
  if (!(await db.wakeOk())) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  // BUG-22: work in small batches with a time budget. claim_push marks what it hands over as sent, so a function
  // killed at its 30 s limit used to lose the rest of a large batch silently. Now at most one batch of 25 is in
  // flight, sending runs in parallel lanes, and the SMS log is written after every batch.
  const started = Date.now();
  const totals = { items: 0, pushed: 0, removed: 0, emailed: 0, texted: 0, failed: 0, batches: 0 };
  // Each batch has a hard ceiling (every request times out after 6 s), so starting a batch before 12 s always
  // finishes well inside Vercel's 30 s limit.
  while (Date.now() - started < 12000) {
    const claim = await db.claim(25);
    if (!claim) return totals.batches ? NextResponse.json({ ok: true, ...totals }) : NextResponse.json({ error: "unauthorized" }, { status: 401 });
    const items = claim.items;
    if (!items.length) break;
    totals.batches++;
    totals.items += items.length;
    await deliver(db, claim.keys, items, totals);
  }
  return NextResponse.json({ ok: true, ...totals });
}

async function deliver(db: Api, keys: Keys, items: Item[], totals: Record<string, number>) {
  // Push notifications (TM-12: a neutral line by kind on the lock screen; the details open in the app)
  if (keys.vapid_public && keys.vapid_private) {
    webpush.setVapidDetails(keys.subject, keys.vapid_public, keys.vapid_private);
    const subs = items.flatMap((it) => it.subs.map((s) => ({ it, s })));
    const dead: string[] = [];
    const res = await runPool(subs, 10, async ({ it, s }) => {
      try {
        await webpush.sendNotification(
          s,
          pushPayload(it),
          { TTL: it.kind.startsWith("reminder") ? 3600 : 86400, urgency: it.kind === "reminder_soon" || it.kind === "message" ? "high" : "normal", timeout: 6000 }
        );
      } catch (e: any) {
        if (e?.statusCode === 404 || e?.statusCode === 410) dead.push(s.endpoint);
        throw e;
      }
    });
    totals.pushed += res.filter((r) => r.ok).length;
    if (dead.length) {
      totals.removed += dead.length;
      await db.drop(dead);
    }
  }

  // Day-before reminders also go by email when an email service is configured (2 at a time: Resend's rate limit).
  const key = process.env.RESEND_API_KEY;
  const from = process.env.REMINDER_FROM_EMAIL ?? process.env.ALERT_FROM_EMAIL;
  if (key && from) {
    const res = await runPool(items.filter((it) => it.email), 2, async (it) => {
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        signal: AbortSignal.timeout(6000),
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
      if (!r.ok) throw new Error(`resend ${r.status}`);
    });
    totals.emailed += res.filter((r) => r.ok).length;
  }

  // Reminders, moved and cancelled lessons also go by SMS (019) to people who allowed it; every attempt is logged.
  if (smsConfigured()) {
    const res = await runPool(items.filter((x) => x.phone), 5, (it) => sendSms(it.phone!, `Classi: ${it.body}`));
    const log = res.map((r) => ({ id: r.item.id, phone: r.item.phone!, ok: r.ok && r.value.ok, detail: r.ok ? r.value.detail : r.error }));
    totals.texted += log.filter((l) => l.ok).length;
    totals.failed += log.filter((l) => !l.ok).length;
    if (log.length) await db.log(log);
  }
}


