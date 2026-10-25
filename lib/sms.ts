// SMS through 019 (https://docs.019sms.co.il). Configured with Vercel environment variables:
//   SMS_019_TOKEN  – API token (019 → Settings → API Token Management)
//   SMS_019_USER   – the 019 account username
//   SMS_SENDER     – sender name shown on the phone, up to 11 English letters/digits (default "Classi")
//   SMS_019_TEST=1 – optional: validate requests without sending (019 test endpoint)

export const smsConfigured = () => !!(process.env.SMS_019_TOKEN && process.env.SMS_019_USER);

const localPhone = (p: string) => p.replace(/[^0-9+]/g, "").replace(/^\+?972/, "0");

export async function sendSms(phone: string, message: string, test = process.env.SMS_019_TEST === "1"): Promise<{ ok: boolean; detail: string }> {
  const token = process.env.SMS_019_TOKEN;
  const user = process.env.SMS_019_USER;
  if (!token || !user) return { ok: false, detail: "not configured" };
  const sender = (process.env.SMS_SENDER || "Classi").replace(/[^A-Za-z0-9]/g, "").slice(0, 11) || "Classi";
  try {
    const r = await fetch(`https://019sms.co.il/api${test ? "/test" : ""}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        sms: {
          user: { username: user },
          source: sender,
          destinations: { phone: [{ _: localPhone(phone) }] },
          message: message.slice(0, 1000),
        },
      }),
      cache: "no-store",
    });
    const j = (await r.json().catch(() => ({}))) as { status?: number | string; message?: string; shipment_id?: string };
    const ok = r.ok && Number(j.status) === 0;
    return { ok, detail: ok ? `shipment ${j.shipment_id ?? ""}`.trim() : `${j.status ?? r.status}: ${j.message ?? r.statusText}` };
  } catch (e: any) {
    return { ok: false, detail: String(e?.message ?? e) };
  }
}
