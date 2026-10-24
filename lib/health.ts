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

/** Each service is checked on its own, so one failure doesn't hide the others. */
export async function runHealthChecks() {
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
    timed("email", "إرسال البريد (Resend)", async () => {
      const resend = process.env.RESEND_API_KEY;
      if (!resend) throw new Error("SKIP: أضف RESEND_API_KEY في Vercel لتفعيل هذا الفحص");
      const r = await fetch("https://api.resend.com/domains", { headers: { Authorization: `Bearer ${resend}` }, cache: "no-store" });
      if (r.status === 401 || r.status === 403) throw new Error("مفتاح Resend غير صالح");
      if (!r.ok) throw new Error(`رمز الاستجابة ${r.status}`);
      const body = (await r.json()) as { data?: { name: string; status: string }[] };
      const domains = body.data ?? [];
      const verified = domains.filter((d) => d.status === "verified");
      if (!verified.length) throw new Error("لا يوجد نطاق موثّق في Resend، الرسائل لن تصل للمستخدمين");
      return `النطاق موثّق: ${verified.map((d) => d.name).join("، ")}`;
    }),
  ]);
  return { ok: checks.every((c) => c.status !== "fail"), checked_at: new Date().toISOString(), checks };
}
