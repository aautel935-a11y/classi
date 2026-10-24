"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export function NewPasswordForm() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const a = String(f.get("p1"));
    if (a !== String(f.get("p2"))) return setError("كلمتا المرور غير متطابقتين.");
    setBusy(true);
    setError(null);
    const { error } = await createClient().auth.updateUser({ password: a });
    setBusy(false);
    if (error) return setError(error.message.includes("Password") ? "استعمل 8 أحرف على الأقل." : error.message);
    setDone(true);
    setTimeout(() => router.push("/account"), 1500);
  }

  if (done) return <p className="okmsg">تم تغيير كلمة المرور.</p>;
  return (
    <form className="formstack" onSubmit={onSubmit}>
      <label className="field" htmlFor="p1">كلمة المرور الجديدة<input id="p1" name="p1" type="password" minLength={8} required dir="ltr" autoComplete="new-password" /></label>
      <label className="field" htmlFor="p2">أعد كتابتها<input id="p2" name="p2" type="password" minLength={8} required dir="ltr" autoComplete="new-password" /></label>
      {error && <p className="err">{error}</p>}
      <button className="btn block" disabled={busy}>{busy ? "لحظة…" : "حفظ"}</button>
    </form>
  );
}
