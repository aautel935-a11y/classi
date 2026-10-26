"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { TOWNS } from "@/lib/types";

const ROLES = [
  ["guardian", "ولي أمر"],
  ["student", "طالب"],
  ["teacher", "معلم"],
  ["institute", "معهد"],
] as const;

function EmailForm({ next, onBack }: { next: string; onBack: () => void }) {
  const router = useRouter();
  const [mode, setMode] = useState<"in" | "up" | "reset">("in");
  const [role, setRole] = useState<string>("guardian");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const f = new FormData(e.currentTarget);
    const supabase = createClient();
    const email = String(f.get("email")).trim();
    const password = String(f.get("password"));
    if (mode === "reset") {
      const { error } = await supabase.auth.resetPasswordForEmail(email, {
        redirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent("/account/password")}`,
      });
      setBusy(false);
      if (error) return setError(/rate|limit|seconds/i.test(error.message) ? "أُرسلت رسائل كثيرة خلال وقت قصير. انتظر قليلاً ثم حاول مرة أخرى." : error.message);
      setSent(true);
      return;
    }
    if (mode === "in") {
      const { error } = await supabase.auth.signInWithPassword({ email, password });
      setBusy(false);
      if (error) return setError(error.message === "Invalid login credentials" ? "البريد أو كلمة المرور غير صحيحة." : error.message);
      router.push(next);
      router.refresh();
      return;
    }
    const role = String(f.get("role"));
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: { full_name: String(f.get("full_name")).trim(), role, town: String(f.get("town") || ""), phone: String(f.get("phone") || "").trim(), terms_accepted_at: new Date().toISOString(), ...(role === "student" ? { guardian_consent_at: new Date().toISOString() } : {}) },
        emailRedirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent(role === "teacher" ? "/teach" : role === "institute" ? "/manage" : next)}&role=${role}`,
      },
    });
    setBusy(false);
    if (error) return setError(error.message.includes("Password") ? "كلمة المرور قصيرة، استعمل 8 أحرف على الأقل." : error.message);
    if (data.session) {
      await supabase.from("profiles").update({ roles: [role], active_role: role, town: String(f.get("town")) || null }).eq("id", data.user!.id);
      router.push(role === "teacher" ? "/teach" : role === "institute" ? "/manage" : next);
      router.refresh();
    } else {
      setSent(true);
    }
  }

  if (sent)
    return (
      <div className="stack">
        <h1>افحص بريدك</h1>
        <p>{mode === "reset" ? "أرسلنا لك رابطاً لتعيين كلمة مرور جديدة." : "أرسلنا لك رابط تفعيل. اضغط عليه لإكمال إنشاء الحساب، ثم ستعود إلى Classi تلقائياً."}</p>
        <p className="small muted">لم تصل الرسالة؟ افحص مجلد الرسائل غير المرغوب فيها (Spam)، أو انتظر دقيقتين.</p>
      </div>
    );

  return (
    <form className="formstack" onSubmit={onSubmit}>
      <h1>{mode === "reset" ? "نسيت كلمة المرور" : "الدخول بالبريد الإلكتروني"}</h1>
      <p className="small muted">للحسابات القديمة التي أُنشئت بالبريد. يمكنك بعد الدخول ربط رقم هاتفك من «حسابي» لتدخل بالهاتف في المرة القادمة.</p>
      {mode === "up" && (
        <>
          <label className="field" htmlFor="full_name">
            الاسم الكامل
            <input id="full_name" name="full_name" required autoComplete="name" />
          </label>
          <fieldset>
            <legend>أنا</legend>
            <div className="filters">
              {ROLES.map(([k, l], i) => (
                <label key={k} className="radio-opt">
                  <input type="radio" name="role" value={k} defaultChecked={i === 0} onChange={() => setRole(k)} />
                  {l}
                </label>
              ))}
            </div>
          </fieldset>
          <label className="field" htmlFor="phone">
            رقم الجوال (اختياري)
            <input id="phone" name="phone" type="tel" dir="ltr" inputMode="tel" placeholder="050-1234567" autoComplete="tel" />
            <span className="small muted">لتذكيرات الحصص برسالة نصية أو واتساب.</span>
          </label>
          <label className="field" htmlFor="town">
            البلد
            <select id="town" name="town" defaultValue="باقة الغربية">
              {TOWNS.map((t) => <option key={t}>{t}</option>)}
            </select>
          </label>
        </>
      )}
      <label className="field" htmlFor="email">
        البريد الإلكتروني
        <input id="email" name="email" type="email" required autoComplete="email" dir="ltr" />
      </label>
      {mode !== "reset" && (
      <label className="field" htmlFor="password">
        كلمة المرور
        <input id="password" name="password" type="password" required minLength={8} autoComplete={mode === "in" ? "current-password" : "new-password"} dir="ltr" />
      </label>
      )}
      {mode === "in" && (
        <button type="button" className="link small" style={{ alignSelf: "flex-start" }} onClick={() => { setMode("reset"); setError(null); }}>نسيت كلمة المرور؟</button>
      )}
      {mode === "reset" && (
        <button type="button" className="link small" style={{ alignSelf: "flex-start" }} onClick={() => { setMode("in"); setError(null); }}>العودة لتسجيل الدخول</button>
      )}
      {mode === "up" && role === "student" && (
        <label className="row small consent" style={{ alignItems: "flex-start" }}>
          <input type="checkbox" name="guardian_ok" required style={{ marginTop: 3 }} />
          <span>
            أقرّ بأن عمري 18 سنة أو أكثر، <b>أو</b> أنني أستعمل Classi بإذن من أهلي وبمعرفتهم، ويوجد معي شخص بالغ مسؤول عني يتابع حجوزاتي.
          </span>
        </label>
      )}
      {mode === "up" && (
        <label className="row small" style={{ alignItems: "flex-start" }}>
          <input type="checkbox" name="terms" required style={{ marginTop: 3 }} />
          <span>
            قرأت وأوافق على <a className="link" href="/terms" target="_blank">شروط الاستخدام</a> و<a className="link" href="/privacy" target="_blank">سياسة الخصوصية</a>.
          </span>
        </label>
      )}
      {error && <p className="err">{error}</p>}
      <button className="btn block" disabled={busy}>{busy ? "لحظة…" : mode === "in" ? "دخول" : mode === "up" ? "إنشاء الحساب" : "أرسل رابط التعيين"}</button>
      <button type="button" className="link small" onClick={onBack}>← الدخول برقم الهاتف</button>

    </form>
  );
}

/** "050-123 4567" → "+972501234567", or null when it is not an Israeli mobile number. */
function toE164(raw: string) {
  const d = raw.replace(/[^0-9+]/g, "");
  return /^(\+?972|0)5\d{8}$/.test(d) ? d.replace(/^(\+?972|0)/, "+972") : null;
}

function otpError(m: string) {
  if (/signups? not allowed|user not found/i.test(m)) return "NOT_FOUND";
  if (/expired|invalid|token/i.test(m)) return "الرمز غير صحيح أو انتهت صلاحيته. اطلب رمزاً جديداً.";
  if (/rate|limit|seconds|too many/i.test(m)) return "طلبت رموزاً كثيرة خلال وقت قصير. انتظر دقيقة ثم حاول مرة أخرى.";
  if (/sms|hook|send/i.test(m)) return "تعذّر إرسال الرسالة الآن. تأكد من الرقم وحاول بعد قليل.";
  return m;
}

/** Sign in or sign up with a phone number and a 6-digit SMS code. */
export function LoginForm({ next, initial = "in" }: { next: string; initial?: "in" | "up" }) {
  const router = useRouter();
  const [useEmail, setUseEmail] = useState(false);
  const [mode, setMode] = useState<"in" | "up">(initial);
  const [role, setRole] = useState<string>("guardian");
  const [step, setStep] = useState<"phone" | "code">("phone");
  const [phone, setPhone] = useState<string>("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [wait, setWait] = useState(0);
  const meta = useRef<Record<string, string> | null>(null);
  const codeRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (wait <= 0) return;
    const t = setTimeout(() => setWait(wait - 1), 1000);
    return () => clearTimeout(t);
  }, [wait]);
  useEffect(() => { if (step === "code") codeRef.current?.focus(); }, [step]);

  if (useEmail) return <EmailForm next={next} onBack={() => setUseEmail(false)} />;

  async function sendCode(e164: string, signup: boolean) {
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithOtp({
      phone: e164,
      options: { shouldCreateUser: signup, channel: "sms", ...(signup && meta.current ? { data: meta.current } : {}) },
    });
    return error ? otpError(error.message) : null;
  }

  async function onPhone(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    const f = new FormData(e.currentTarget);
    const e164 = toE164(String(f.get("phone") ?? ""));
    if (!e164) return setError("اكتب رقم جوال إسرائيلي صحيح، مثل 050-1234567.");
    if (mode === "up") {
      const r = String(f.get("role"));
      meta.current = {
        full_name: String(f.get("full_name") ?? "").trim(), role: r, town: String(f.get("town") ?? ""),
        terms_accepted_at: new Date().toISOString(), ...(r === "student" ? { guardian_consent_at: new Date().toISOString() } : {}),
      };
    }
    setBusy(true);
    const err = await sendCode(e164, mode === "up");
    setBusy(false);
    if (err === "NOT_FOUND") {
      setPhone(e164);
      setMode("up");
      return setError("هذا الرقم غير مسجّل بعد. أكمل بياناتك لإنشاء حساب جديد.");
    }
    if (err) return setError(err);
    setPhone(e164);
    setStep("code");
    setWait(60);
  }

  async function onCode(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    const token = String(new FormData(e.currentTarget).get("code") ?? "").replace(/\D/g, "");
    if (token.length !== 6) return setError("الرمز من 6 أرقام.");
    setBusy(true);
    const supabase = createClient();
    const { data, error } = await supabase.auth.verifyOtp({ phone, token, type: "sms" });
    if (error || !data.user) {
      setBusy(false);
      return setError(otpError(error?.message ?? "invalid"));
    }
    const { data: p } = await supabase.from("profiles").select("active_role").eq("id", data.user.id).maybeSingle();
    const r = p?.active_role;
    router.push(next !== "/" ? next : r === "teacher" ? "/teach" : r === "institute" ? "/manage" : "/");
    router.refresh();
  }

  async function resend() {
    setError(null);
    setBusy(true);
    const err = await sendCode(phone, mode === "up");
    setBusy(false);
    if (err && err !== "NOT_FOUND") return setError(err);
    setWait(60);
  }

  if (step === "code")
    return (
      <form className="formstack" onSubmit={onCode}>
        <h1>أدخل الرمز</h1>
        <p>أرسلنا رسالة فيها رمز من 6 أرقام إلى <b className="num" dir="ltr">{phone.replace(/^\+972/, "0")}</b>.</p>
        <label className="field" htmlFor="code">
          الرمز
          <input ref={codeRef} id="code" name="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]*" maxLength={6} required dir="ltr"
                 className="otp" placeholder="••••••" onInput={(e) => { const v = (e.target as HTMLInputElement).value.replace(/\D/g, ""); (e.target as HTMLInputElement).value = v; if (v.length === 6) (e.target as HTMLInputElement).form?.requestSubmit(); }} />
        </label>
        {error && <p className="err">{error}</p>}
        <button className="btn block" disabled={busy}>{busy ? "لحظة…" : "دخول"}</button>
        <div className="row between small">
          <button type="button" className="link" onClick={() => { setStep("phone"); setError(null); }}>تغيير الرقم</button>
          {wait > 0 ? <span className="muted num">إعادة الإرسال بعد {wait} ث</span> : <button type="button" className="link" onClick={resend} disabled={busy}>أرسل الرمز مرة أخرى</button>}
        </div>
      </form>
    );

  return (
    <form className="formstack" onSubmit={onPhone}>
      <h1>{mode === "in" ? "تسجيل الدخول" : "حساب جديد"}</h1>
      <div className="seg" role="group" style={{ gridTemplateColumns: "1fr 1fr" }}>
        <button type="button" aria-pressed={mode === "in"} onClick={() => { setMode("in"); setError(null); }}>لدي حساب</button>
        <button type="button" aria-pressed={mode === "up"} onClick={() => { setMode("up"); setError(null); }}>حساب جديد</button>
      </div>
      {mode === "up" && (
        <>
          <label className="field" htmlFor="full_name">
            الاسم الكامل
            <input id="full_name" name="full_name" required minLength={2} autoComplete="name" />
          </label>
          <fieldset>
            <legend>أنا</legend>
            <div className="filters">
              {ROLES.map(([k, l]) => (
                <label key={k} className="radio-opt">
                  <input type="radio" name="role" value={k} checked={role === k} onChange={() => setRole(k)} />
                  {l}
                </label>
              ))}
            </div>
          </fieldset>
          <label className="field" htmlFor="town">
            البلد
            <select id="town" name="town" defaultValue="باقة الغربية">
              {TOWNS.map((t) => <option key={t}>{t}</option>)}
            </select>
          </label>
        </>
      )}
      <label className="field" htmlFor="phone">
        رقم الجوال
        <input id="phone" name="phone" type="tel" dir="ltr" inputMode="tel" placeholder="050-1234567" autoComplete="tel" required defaultValue={phone.replace(/^\+972/, "0")} />
      </label>
      {mode === "up" && role === "student" && (
        <label className="row small consent" style={{ alignItems: "flex-start" }}>
          <input type="checkbox" name="guardian_ok" required style={{ marginTop: 3 }} />
          <span>
            أقرّ بأن عمري 18 سنة أو أكثر، <b>أو</b> أنني أستعمل Classi بإذن من أهلي وبمعرفتهم، ويوجد معي شخص بالغ مسؤول عني يتابع حجوزاتي.
          </span>
        </label>
      )}
      {mode === "up" && (
        <label className="row small" style={{ alignItems: "flex-start" }}>
          <input type="checkbox" name="terms" required style={{ marginTop: 3 }} />
          <span>
            قرأت وأوافق على <a className="link" href="/terms" target="_blank">شروط الاستخدام</a> و<a className="link" href="/privacy" target="_blank">سياسة الخصوصية</a>، وعلى استلام رسائل SMS عن حصصي.
          </span>
        </label>
      )}
      {error && <p className="err">{error}</p>}
      <button className="btn block" disabled={busy}>{busy ? "لحظة…" : "أرسل رمز الدخول"}</button>
      <p className="small muted" style={{ textAlign: "center" }}>بلا كلمة مرور: نرسل لك رمزاً برسالة SMS.</p>
      <button type="button" className="link small" onClick={() => setUseEmail(true)}>لدي حساب قديم بالبريد الإلكتروني</button>
    </form>
  );
}
