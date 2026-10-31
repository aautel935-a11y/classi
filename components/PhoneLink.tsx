"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

const toE164 = (raw: string) => {
  const d = raw.replace(/[^0-9+]/g, "");
  return /^(\+?972|0)5\d{8}$/.test(d) ? d.replace(/^(\+?972|0)/, "+972") : null;
};
const local = (p: string | null) => (p ? p.replace(/^\+?972/, "0") : "");

/** The phone used to sign in. Adding or changing it is confirmed with an SMS code to the new number. */
export function PhoneLink({ loginPhone, profilePhone }: { loginPhone: string | null; profilePhone: string | null }) {
  const router = useRouter();
  const [open, setOpen] = useState(!loginPhone);
  const [phone, setPhone] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [wait, setWait] = useState(0);
  useEffect(() => {
    if (wait <= 0) return;
    const t = setTimeout(() => setWait(wait - 1), 1000);
    return () => clearTimeout(t);
  }, [wait]);

  async function resend() {
    if (!phone) return;
    setMsg(null);
    setBusy(true);
    const { error } = await createClient().auth.updateUser({ phone });
    setBusy(false);
    if (error) return setMsg({ ok: false, text: /rate|seconds/i.test(error.message) ? "انتظر دقيقة ثم حاول مرة أخرى." : "تعذّر إرسال الرمز الآن. حاول بعد قليل." });
    setWait(60);
    setMsg({ ok: true, text: "أرسلنا رمزاً جديداً." });
  }

  async function send(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setMsg(null);
    const e164 = toE164(String(new FormData(e.currentTarget).get("phone") ?? ""));
    if (!e164) return setMsg({ ok: false, text: "اكتب رقم جوال صحيح، مثل 050-1234567." });
    setBusy(true);
    const { error } = await createClient().auth.updateUser({ phone: e164 });
    setBusy(false);
    if (error) {
      return setMsg({ ok: false, text: /already|registered|exists/i.test(error.message) ? "هذا الرقم مربوط بحساب آخر في Classi. ادخل به مباشرة من صفحة الدخول." : /rate|seconds/i.test(error.message) ? "انتظر دقيقة ثم حاول مرة أخرى." : "تعذّر إرسال الرمز الآن. حاول بعد قليل." });
    }
    setPhone(e164);
    setWait(60);
  }

  async function verify(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setMsg(null);
    const token = String(new FormData(e.currentTarget).get("code") ?? "").replace(/\D/g, "");
    setBusy(true);
    const { error } = await createClient().auth.verifyOtp({ phone: phone!, token, type: "phone_change" });
    setBusy(false);
    if (error) return setMsg({ ok: false, text: "الرمز غير صحيح أو انتهت صلاحيته." });
    setPhone(null);
    setOpen(false);
    setMsg({ ok: true, text: "رُبط الرقم بحسابك. من الآن تدخل برقم الهاتف ورمز SMS." });
    router.refresh();
  }

  return (
    <div className="card formstack" id="phone">
      <div className="row between">
        <span>
          <b>رقم الدخول</b>
          <span className="small muted" style={{ display: "block" }}>
            {loginPhone ? <span className="num" dir="ltr">{local(loginPhone)}</span> : "لم تربط رقماً بعد، تدخل بالبريد وكلمة المرور."}
          </span>
        </span>
        {!open && <button type="button" className="link small" onClick={() => setOpen(true)}>{loginPhone ? "تغيير الرقم" : "ربط رقم"}</button>}
      </div>
      {msg && <p className={msg.ok ? "okmsg" : "err"}>{msg.text}</p>}
      {open && !phone && (
        <form onSubmit={send} className="row" style={{ gap: 8 }}>
          <input name="phone" type="tel" dir="ltr" inputMode="tel" placeholder="050-1234567" defaultValue={local(profilePhone)} style={{ flex: 1, minWidth: 0 }} aria-label="رقم الجوال" />
          <button className="btn sm" disabled={busy}>{busy ? "…" : "أرسل رمزاً"}</button>
        </form>
      )}
      {phone && (
        <form onSubmit={verify} className="row" style={{ gap: 8 }}>
          <input name="code" inputMode="numeric" autoComplete="one-time-code" maxLength={6} placeholder="الرمز" dir="ltr" className="otp" style={{ flex: 1, minWidth: 0, fontSize: 20 }} aria-label="رمز التأكيد" autoFocus />
          <button className="btn sm okb" disabled={busy}>تأكيد</button>
        </form>
      )}
      {phone && (
        <div className="row between small" style={{ flexWrap: "wrap", gap: 8 }}>
          <span className="muted">لم تصل الرسالة؟ تأكد أن الرقم صحيح وأنه رقم جوال إسرائيلي، ثم اطلب رمزاً جديداً بعد دقيقة.</span>
          {wait > 0 ? <span className="muted num">إعادة الإرسال بعد {wait} ث</span> : <button type="button" className="link" onClick={resend} disabled={busy}>أرسل الرمز مرة أخرى</button>}
          <button type="button" className="link" onClick={() => { setPhone(null); setMsg(null); }}>تغيير الرقم</button>
        </div>
      )}
    </div>
  );
}
