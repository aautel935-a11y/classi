"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { bookAction } from "@/app/actions";
import { dayLong, dayNum, dayShort, monthName, time } from "@/lib/format";
import { PLACES, type OfferingType, type Place } from "@/lib/types";
import type { Slot } from "@/lib/dates";

type Props = {
  offering: { id: string; type: OfferingType; title: string; price: number; seats: number | null; full: boolean; places: Place[] };
  slots: Slot[];
  groupSessions: { id: string; starts_at: string; taken: number }[];
  kids: { id: string; name: string; grade: string | null }[];
};

const ACTION: Record<OfferingType, string> = { private: "اختر موعداً", group: "احجز مقعداً", course: "سجّل في الدورة", recorded: "اشترِ المحتوى" };
const DONE: Record<OfferingType, string> = { private: "إرسال طلب الحجز", group: "تأكيد الحجز", course: "تأكيد التسجيل", recorded: "إتمام الشراء" };

export function BookingFlow({ offering: o, slots, groupSessions, kids }: Props) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState(0);
  const [day, setDay] = useState<string | null>(null);
  const [slot, setSlot] = useState<Slot | null>(null);
  const [session, setSession] = useState<string | null>(null);
  const [who, setWho] = useState<string | null>(null); // child id or "self"
  const [pay, setPay] = useState<string | null>(null);
  const [weekly, setWeekly] = useState(false);
  const [mode, setMode] = useState<Place | null>(o.places.length === 1 ? o.places[0] : null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const chooseMode = o.type !== "recorded" && o.places.length > 1;
  const steps = [
    ...(o.type === "private" ? ["slot"] : o.type === "group" ? ["session"] : []),
    ...(chooseMode ? ["mode"] : []),
    "who",
    "pay",
  ];
  const st = steps[step];
  const days = useMemo(() => Array.from(new Set(slots.map((s) => s.day))), [slots]);
  const curDay = day ?? days[0];
  const pays = o.type === "course" ? [["bit", "Bit"], ["installments", "3 دفعات"], ["cash", "نقداً في المعهد"]] : o.type === "recorded" ? [["bit", "Bit"], ["card", "بطاقة ائتمان"]] : [["bit", "Bit"], ["cash", "نقداً للمعلم"]];
  const ready = (st === "slot" && slot) || (st === "session" && session) || (st === "mode" && mode) || (st === "who" && who) || (st === "pay" && pay);
  const whoName = who === "self" ? "أنا" : kids.find((k) => k.id === who)?.name;
  const chosenAt = slot?.at ?? groupSessions.find((g) => g.id === session)?.starts_at;

  function submit() {
    setError(null);
    start(async () => {
      const r = await bookAction({
        offeringId: o.id,
        childId: who === "self" ? null : who,
        startsAt: slot?.at ?? null,
        sessionId: session,
        pay: pay!,
        weekly,
        mode,
      });
      if (r.error) return setError(r.error);
      setOpen(false);
      router.push("/schedule?booked=1");
    });
  }

  if (o.full) return <button className="btn block" disabled>الدورة ممتلئة</button>;

  return (
    <>
      <button className="btn block" onClick={() => { setOpen(true); setStep(0); setError(null); }}>
        {ACTION[o.type]}
      </button>
      {open && (
        <>
          <div className="scrim" onClick={() => setOpen(false)} />
          <div className="sheet" dir="rtl" role="dialog" aria-modal="true" aria-label="حجز">
            <div className="grab" />
            <div className="wrap">
              <div className="steps">{steps.map((_, i) => <i key={i} className={i <= step ? "on" : ""} />)}</div>

              {st === "slot" && (
                <>
                  <h2>اختر الموعد</h2>
                  {days.length === 0 ? (
                    <p className="empty">لا توجد أوقات فارغة هذا الأسبوع. راسل المعلم أو جرّب لاحقاً.</p>
                  ) : (
                    <>
                      <div className="days">
                        {days.map((d) => (
                          <button key={d} className="day" aria-pressed={d === curDay} onClick={() => { setDay(d); setSlot(null); }}>
                            {dayShort(`${d}T12:00:00Z`)}
                            <b className="num">{dayNum(`${d}T12:00:00Z`)}</b>
                            {monthName(`${d}T12:00:00Z`)}
                          </button>
                        ))}
                      </div>
                      <div className="slots">
                        {slots.filter((s) => s.day === curDay).map((s) => (
                          <button key={s.at} className="slot" disabled={s.busy} aria-pressed={slot?.at === s.at} onClick={() => setSlot(s)}>
                            {s.time}
                          </button>
                        ))}
                      </div>
                      <label className="row small">
                        <input type="checkbox" checked={weekly} onChange={(e) => setWeekly(e.target.checked)} /> أريد نفس الموعد كل أسبوع
                      </label>
                    </>
                  )}
                </>
              )}

              {st === "session" && (
                <>
                  <h2>اختر اللقاء</h2>
                  {groupSessions.length === 0 && <p className="empty">لا لقاءات قادمة لهذه المجموعة.</p>}
                  {groupSessions.map((g) => {
                    const full = o.seats != null && g.taken >= o.seats;
                    return (
                      <button key={g.id} className="opt" disabled={full} aria-pressed={session === g.id} onClick={() => setSession(g.id)}>
                        <span className="dot" />
                        <span>
                          {dayLong(g.starts_at)} · <span className="num">{time(g.starts_at)}</span>
                        </span>
                        <span className="spacer small muted num">{full ? "ممتلئ" : `${(o.seats ?? 0) - g.taken} مقاعد`}</span>
                      </button>
                    );
                  })}
                </>
              )}

              {st === "mode" && (
                <>
                  <h2>كيف تريد الحضور؟</h2>
                  {o.places.map((p) => (
                    <button key={p} className="opt" aria-pressed={mode === p} onClick={() => setMode(p)}>
                      <span className="dot" />
                      <span>
                        {p === "online" ? "أونلاين (زوم أو ميت)" : p === "home" ? "حضوري" : PLACES[p]}
                        {p === "home" && o.type === "private" && <span className="muted small"> · تتفقان على المكان في الرسائل</span>}
                      </span>
                    </button>
                  ))}
                </>
              )}

              {st === "who" && (
                <>
                  <h2>{o.type === "course" ? "من سيسجّل؟" : o.type === "recorded" ? "لمن المحتوى؟" : "من سيحضر؟"}</h2>
                  <button className="opt" aria-pressed={who === "self"} onClick={() => setWho("self")}>
                    <span className="dot" />
                    <span>أنا</span>
                  </button>
                  {kids.map((k) => (
                    <button key={k.id} className="opt" aria-pressed={who === k.id} onClick={() => setWho(k.id)}>
                      <span className="dot" />
                      <span>
                        {k.name} {k.grade && <span className="muted small">{k.grade}</span>}
                      </span>
                    </button>
                  ))}
                  <a className="link small" href="/account#children">
                    إضافة ابن أو ابنة
                  </a>
                </>
              )}

              {st === "pay" && (
                <>
                  <h2>الدفع</h2>
                  {pays.map(([k, label]) => (
                    <button key={k} className="opt" aria-pressed={pay === k} onClick={() => setPay(k)}>
                      <span className="dot" />
                      <span>{label}</span>
                    </button>
                  ))}
                  <div className="summary">
                    <div>
                      <span>العرض</span>
                      <span>{o.title}</span>
                    </div>
                    {chosenAt && (
                      <div>
                        <span>الموعد</span>
                        <span>
                          {dayLong(chosenAt)} · {time(chosenAt)}
                        </span>
                      </div>
                    )}
                    <div>
                      <span>الطالب</span>
                      <span>{whoName}</span>
                    </div>
                    {mode && o.type !== "recorded" && (
                      <div>
                        <span>الحضور</span>
                        <span>{mode === "online" ? "أونلاين" : PLACES[mode]}</span>
                      </div>
                    )}
                    {pay === "installments" && (
                      <div>
                        <span>كل دفعة</span>
                        <span className="num">{Math.round(o.price / 3)} ₪</span>
                      </div>
                    )}
                    <div className="total">
                      <span>المجموع</span>
                      <span className="num">{o.price} ₪</span>
                    </div>
                  </div>
                  <p className="note">
                    {o.type === "private"
                      ? "يصل الطلب للمعلم، وتصلك رسالة عند التأكيد. الدفع للمعلم مباشرة في هذه المرحلة."
                      : "يصلك تأكيد في الإشعارات. الدفع الإلكتروني يُضاف في المرحلة القادمة."}
                  </p>
                </>
              )}

              {error && <p className="err">{error}</p>}
              <div className="row">
                {step > 0 && (
                  <button className="btn ghost" onClick={() => setStep(step - 1)}>
                    السابق
                  </button>
                )}
                <button
                  className="btn"
                  style={{ flex: 1 }}
                  disabled={!ready || pending}
                  onClick={() => (step === steps.length - 1 ? submit() : setStep(step + 1))}
                >
                  {pending ? "جارٍ الحفظ…" : step === steps.length - 1 ? DONE[o.type] : "التالي"}
                </button>
              </div>
            </div>
          </div>
        </>
      )}
    </>
  );
}
