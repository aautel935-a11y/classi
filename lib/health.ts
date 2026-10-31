import { sendSms, smsConfigured } from "@/lib/sms";
import { publicClient } from "./supabase/public";

export type Check = { name: string; label: string; status: "ok" | "fail" | "skipped"; detail: string; ms: number };

async function timed(name: string, label: string, fn: () => Promise<string>): Promise<Check> {
  const t = Date.now();
  try {
    const detail = await Promise.race([
      fn(),
      new Promise<string>((_, rej) => setTimeout(() => rej(new Error("لا رد خلال 8 ثوانٍ")), 8000)),
    ]);
    return { name, label, status: "ok", detail, ms: Date.now() - t };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { name, label, status: msg.startsWith("SKIP:") ? "skipped" : "fail", detail: msg.replace(/^SKIP:\s*/, ""), ms: Date.now() - t };
  }
}

/**
 * Each service is checked on its own, so one failure doesn't hide the others.
 * `external: false` skips the Resend and 019 checks (they call paid third-party APIs with production keys),
 * which is what the public /api/health uses.
 */
export async function runHealthChecks({ external = true }: { external?: boolean } = {}) {
  const url = (process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").trim().replace(/\/$/, "");
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";
  const supabase = publicClient();

  const checks = await Promise.all([
    timed("database", "قاعدة البيانات", async () => {
      const { data, error } = await supabase.rpc("health_ping");
      if (error) throw new Error(error.message);
      const row = (Array.isArray(data) ? data[0] : data) as { offerings: number; accounts: number };
      return `تعمل · ${row.offerings} عرضاً · ${row.accounts} حساباً`;
    }),
    timed("storage", "تخزين الصور", async () => {
      const { error } = await supabase.storage.from("avatars").list("", { limit: 1 });
      if (error) throw new Error(error.message);
      return "مجلد الصور متاح";
    }),
    timed("auth", "خدمة تسجيل الدخول", async () => {
      const r = await fetch(`${url}/auth/v1/health`, { headers: { apikey: key }, cache: "no-store" });
      if (!r.ok) throw new Error(`رمز الاستجابة ${r.status}`);
      return "تعمل";
    }),
    ...(!external ? [] : [timed("email", "إرسال البريد (Resend)", async () => {
      const resend = process.env.RESEND_API_KEY;
      if (!resend) throw new Error("SKIP: أضف RESEND_API_KEY في Vercel لتفعيل هذا الفحص");
      const r = await fetch("https://api.resend.com/domains", { headers: { Authorization: `Bearer ${resend}` }, cache: "no-store" });
      if (r.status === 401 || r.status === 403) {
        // A "Sending access" key may not list domains, which proves it is a valid sending key.
        const err = (await r.json().catch(() => ({}))) as { name?: string; message?: string };
        if (err.name === "restricted_api_key" || /restricted|only send/i.test(err.message ?? "")) return "مفتاح الإرسال صالح";
        throw new Error("مفتاح Resend غير صالح");
      }
      if (!r.ok) throw new Error(`رمز الاستجابة ${r.status}`);
      const body = (await r.json()) as { data?: { name: string; status: string }[] };
      const domains = body.data ?? [];
      const verified = domains.filter((d) => d.status === "verified");
      if (!verified.length) throw new Error("لا يوجد نطاق موثّق في Resend، الرسائل لن تصل للمستخدمين");
      return `النطاق موثّق: ${verified.map((d) => d.name).join("، ")}`;
    }),
    timed("sms", "رسائل SMS (019)", async () => {
      if (!smsConfigured()) throw new Error("SKIP: أضف SMS_019_TOKEN وSMS_019_USER في Vercel لتفعيل الرسائل");
      // 019's test endpoint checks the token and request without sending anything.
      const r = await sendSms("0500000000", "Classi health check", true);
      if (!r.ok) throw new Error(`019 رفض الطلب: ${r.detail}`);
      return "الحساب والمفتاح سليمان";
    })]),
  ]);
  return { ok: checks.every((c) => c.status !== "fail"), checked_at: new Date().toISOString(), checks };
}
