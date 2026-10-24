"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { TOWNS } from "@/lib/types";

const ROLES = [
  ["guardian", "ولي أمر"],
  ["student", "طالب"],
  ["teacher", "معلم"],
  ["institute", "معهد"],
] as const;

export function LoginForm({ next, initial = "in" }: { next: string; initial?: "in" | "up" }) {
  const router = useRouter();
  const [mode, setMode] = useState<"in" | "up" | "reset">(initial);
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
      <h1>{mode === "in" ? "تسجيل الدخول" : mode === "up" ? "حساب جديد" : "نسيت كلمة المرور"}</h1>
      <div className="seg" role="group" style={{ gridTemplateColumns: "1fr 1fr" }}>
        <button type="button" aria-pressed={mode === "in"} onClick={() => setMode("in")}>لدي حساب</button>
        <button type="button" aria-pressed={mode === "up"} onClick={() => setMode("up")}>حساب جديد</button>
      </div>
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

    </form>
  );
}
