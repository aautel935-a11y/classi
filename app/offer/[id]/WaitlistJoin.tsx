"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { joinWaitlistAction } from "@/app/actions";
import type { OfferingType } from "@/lib/types";

const WHY: Record<OfferingType, string> = {
  private: "لا توجد أوقات فارغة عند المعلم حالياً.",
  group: "كل اللقاءات القادمة ممتلئة.",
  course: "الدورة ممتلئة.",
  recorded: "",
};

export function WaitlistJoin({ offering, kids, owner }: { offering: { id: string; type: OfferingType }; kids: { id: string; name: string }[]; owner: "teacher" | "institute" }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [who, setWho] = useState<string>("self");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const ownerWord = owner === "institute" ? "المعهد" : "المعلم";

  function submit() {
    setError(null);
    start(async () => {
      const r = await joinWaitlistAction({ offeringId: offering.id, childId: who === "self" ? null : who, note });
      if (r.error) return setError(r.error);
      setOpen(false);
      router.push(`/offer/${offering.id}?waiting=${r.count ?? 1}`);
      router.refresh();
    });
  }

  return (
    <>
      <p className="note">{WHY[offering.type]} انضم لقائمة الانتظار ونخبرك فور توفّر مكان.</p>
      <button className="btn block" onClick={() => { setOpen(true); setError(null); }}>
        انضم لقائمة الانتظار
      </button>
      {open && (
        <>
          <div className="scrim" onClick={() => setOpen(false)} />
          <div className="sheet" dir="rtl" role="dialog" aria-modal="true" aria-label="قائمة الانتظار">
            <div className="grab" />
            <div className="wrap">
              <h2>قائمة الانتظار</h2>
              <p className="small muted">يصل طلبك لـ{ownerWord} بالترتيب. عندما يتحرّر مكان أو يردّ {ownerWord} يصلك إشعار.</p>
              <h3 className="small">لمن المكان؟</h3>
              <button className="opt" aria-pressed={who === "self"} onClick={() => setWho("self")}>
                <span className="dot" />
                <span>أنا</span>
              </button>
              {kids.map((k) => (
                <button key={k.id} className="opt" aria-pressed={who === k.id} onClick={() => setWho(k.id)}>
                  <span className="dot" />
                  <span>{k.name}</span>
                </button>
              ))}
              <label className="field" htmlFor="wl-note">
                ملاحظة لـ{ownerWord} (اختياري)
                <textarea
                  id="wl-note"
                  rows={2}
                  maxLength={300}
                  value={note}
                  onChange={(e) => setNote(e.target.value)}
                  placeholder={offering.type === "private" ? "مثلاً: الأحد أو الثلاثاء بعد الساعة 5" : "مثلاً: أي لقاء يناسبني"}
                />
              </label>
              {error && <p className="err">{error}</p>}
              <div className="row">
                <button className="btn ghost" onClick={() => setOpen(false)}>إلغاء</button>
                <button className="btn" style={{ flex: 1 }} disabled={pending} onClick={submit}>
                  {pending ? "جارٍ الحفظ…" : "أضفني للقائمة"}
                </button>
              </div>
            </div>
          </div>
        </>
      )}
    </>
  );
}
