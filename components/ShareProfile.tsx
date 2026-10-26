"use client";

import { useState } from "react";

/** "Copy my booking link" for teachers and institutes, with the phone's share sheet when available. */
export function ShareProfile({ url, name }: { url: string; name: string }) {
  const [done, setDone] = useState(false);
  async function share() {
    const text = `احجز عندي مباشرة في Classi: ${name}`;
    try {
      if (navigator.share) {
        await navigator.share({ title: name, text, url });
        return;
      }
    } catch {
      return; // closed the share sheet
    }
    try {
      await navigator.clipboard.writeText(url);
      setDone(true);
      setTimeout(() => setDone(false), 2500);
    } catch {}
  }
  return (
    <div className="card" style={{ gap: 6 }}>
      <b>رابط ملفك للحجز</b>
      <span className="small muted">انشره في الستوري أو مجموعات واتساب: من يفتحه يرى عروضك ومواعيدك ويحجز مباشرة.</span>
      <div className="row" style={{ gap: 8 }}>
        <input readOnly value={url} dir="ltr" aria-label="الرابط" style={{ flex: 1, minWidth: 0, fontSize: 13 }} onFocus={(e) => e.currentTarget.select()} />
        <button type="button" className="btn sm" onClick={share}>{done ? "نُسخ ✓" : "شارك / انسخ"}</button>
      </div>
    </div>
  );
}
