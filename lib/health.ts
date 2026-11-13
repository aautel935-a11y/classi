import { realSmsAllowed, sendSms, smsConfigured } from "@/lib/sms";
import { publicClient } from "./supabase/public";
import { workerClient, workerKeyConfigured } from "./supabase/worker";

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
    ...(!external ? [] : [timed("worker", "مفتاح الإرسال الخادمي (D-08)", async () => {
      // TM-13: push, email, SMS and sign-in codes are claimed with the server-only key. Without it the old public path
      // is used, and that path stops working once step B is applied.
      if (!workerKeyConfigured()) throw new Error("أضف SUPABASE_SERVICE_ROLE_KEY (المفتاح السري لمشروع Supabase) في إعدادات Vercel، بيئة Production فقط");
      const w = workerClient();
      if (!w) throw new Error("NEXT_PUBLIC_SUPABASE_URL غير مضبوط");
      // An empty secret is always refused (false); an error means the key cannot call the worker functions.
      const { data, error } = await w.rpc("worker_wake_ok", { p_secret: "" });
      if (error) throw new Error(error.message.includes("worker_wake_ok") ? "دوال D-08 غير مطبّقة على قاعدة البيانات" : "المفتاح لا يملك صلاحية دوال الإرسال");
      if (data !== false) throw new Error("رد غير متوقع من worker_wake_ok");
      return "مضبوط ويعمل";
    }), timed("alerts", "تنبيه الفحص اليومي", async () => {
      // BUG-06: without these the daily check runs but nobody hears about a failure.
      const missing = ["ADMIN_EMAIL", "CRON_SECRET"].filter((k) => !process.env[k]);
      if (missing.length) throw new Error(`أضف ${missing.join(" و")} في إعدادات Vercel، وإلا لن يصلك بريد عند تعطل خدمة`);
      return "مفعّل: يصل بريد إلى المسؤول عند أي خلل";
    }), timed("email", "إرسال البريد (Resend)", async () => {
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
      // A production deployment in test mode would accept every request and deliver nothing (no sign-in codes).
      if (process.env.VERCEL_ENV === "production" && !realSmsAllowed() && process.env.NEXT_PUBLIC_DEPLOY_ENV !== "staging")
        throw new Error("الرسائل في وضع الاختبار على الإنتاج: لن تصل رموز الدخول. تحقق من SMS_019_TEST ومن نطاق المشروع classi.click");
      if (process.env.NEXT_PUBLIC_DEPLOY_ENV === "staging" && realSmsAllowed() === false && /classi\.click/.test(process.env.VERCEL_PROJECT_PRODUCTION_URL ?? ""))
        throw new Error("مشروع classi.click مضبوط كـ Staging (NEXT_PUBLIC_DEPLOY_ENV=staging): لن تصل رموز الدخول والموقع غير مفهرس");
      return realSmsAllowed() ? "الحساب والمفتاح سليمان (إرسال حقيقي)" : "الحساب والمفتاح سليمان (وضع الاختبار: لا يُرسل شيء)";
    })]),
  ]);
  return { ok: checks.every((c) => c.status !== "fail"), checked_at: new Date().toISOString(), checks };
}
