"use client";

import { useMemo, useState, useTransition, useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { bookAction } from "@/app/actions";
import { dayLong, dayNum, dayShort, monthName, time } from "@/lib/format";
import { PLACES, type OfferingType, type Place } from "@/lib/types";
import type { Slot } from "@/lib/dates";

type Props = {
  offering: { id: string; type: OfferingType; title: string; price: number; seats: number | null; full: boolean; places: Place[]; autoConfirm: boolean; allowWeekly: boolean };
  slots: Slot[];
  groupSessions: { id: string; starts_at: string; taken: number }[];
  kids: { id: string; name: string; grade: string | null }[];
  trialFor?: string[]; // "self" or child ids who can still take the trial lesson
  trialPrice?: number | null;
  packages?: { who: string; remaining: number; size: number }[];
};

const ACTION: Record<OfferingType, string> = { private: "اختر موعداً", group: "احجز مقعداً", course: "سجّل في الدورة", recorded: "اشترِ المحتوى" };
const DONE: Record<OfferingType, string> = { private: "إرسال طلب الحجز", group: "تأكيد الحجز", course: "تأكيد التسجيل", recorded: "إتمام الشراء" };
const WEEKS = 8;

export function BookingFlow({ offering: o, slots, groupSessions, kids, trialFor = [], trialPrice = null, packages = [] }: Props) {
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
  const [trial, setTrial] = useState(true);
  const [pending, start] = useTransition();
  const sheetRef = useRef<HTMLDivElement>(null);

  const chooseMode = o.type !== "recorded" && o.places.length > 1;
  const canWeekly = o.allowWeekly && (o.type === "private" || o.type === "group");
  const steps = [
    ...(o.type === "private" ? ["slot"] : o.type === "group" ? ["session"] : []),
    ...(canWeekly ? ["freq"] : []),
    ...(chooseMode ? ["mode"] : []),
    "who",
    "pay",
  ];
  const st = steps[step];
  const days = useMemo(() => Array.from(new Set(slots.map((s) => s.day))), [slots]);
  const curDay = day ?? days[0];
  const pkg = packages.find((p) => p.who === who && p.remaining > 0);
  const canTrial = o.type === "private" && trialPrice != null && !!who && trialFor.includes(who) && !weekly;
  const useTrial = canTrial && trial;
  const pays = pkg && !useTrial ? [["package", `من الرزمة (بقي ${pkg.remaining} من ${pkg.size})`]] : o.type === "course" ? [["bit", "تحويل عبر Bit"], ["cash", "نقداً في المعهد"], ["installments", "3 دفعات (يُتفق عليها مع المعهد)"]] : o.type === "recorded" ? [["bit", "تحويل عبر Bit"]] : [["bit", "تحويل عبر Bit"], ["cash", "نقداً للمعلم عند الحصة"]];
  // The payment choice is valid only if it is still offered (it depends on who and on weekly/trial: BUG-11).
  const payOk = !!pay && pays.some(([k]) => k === pay);
  const ready = (st === "slot" && slot) || (st === "session" && session) || st === "freq" || (st === "mode" && mode) || (st === "who" && who) || (st === "pay" && payOk);
  const instant = o.type !== "private" || o.autoConfirm;
  const dayName = (iso: string) => dayShort(iso).replace(/^ال/, "");
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
        trial: useTrial,
      });
      if (r.error) return setError(r.error);
      setOpen(false);
      const q = new URLSearchParams({ booked: weekly ? "weekly" : "1", instant: instant ? "1" : "0" });
      if (r.created != null) q.set("created", String(r.created));
      if (r.skipped?.length) q.set("skipped", r.skipped.join("، "));
      router.push(`/schedule?${q}`);
    });
  }

  // Dialog behaviour (A11Y-01): focus moves into the sheet, Tab stays inside it, Esc and a visible button close it,
  // the page behind does not scroll, and focus returns to the button that opened it.
  useEffect(() => {
    if (!open) return;
    const sheet = sheetRef.current;
    const opener = document.activeElement as HTMLElement | null;
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const focusables = () => Array.from(sheet?.querySelectorAll<HTMLElement>('button:not([disabled]),a[href],input:not([disabled]),select,textarea,[tabindex]:not([tabindex="-1"])') ?? []);
    (sheet?.querySelector<HTMLElement>("h2") ?? focusables()[0])?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") { e.preventDefault(); setOpen(false); return; }
      if (e.key !== "Tab") return;
      const f = focusables();
      if (!f.length) return;
      const first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    };
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("keydown", onKey); document.body.style.overflow = prevOverflow; opener?.focus?.(); };
  }, [open]);

  if (o.full) return <button className="btn block" disabled>الدورة ممتلئة</button>;

  return (
    <>
      <button className="btn block" onClick={() => { setOpen(true); setStep(0); setError(null); }}>
        {ACTION[o.type]}
      </button>
      {open && (
        <>
          <div className="scrim" onClick={() => setOpen(false)} />
          <div className="sheet" dir="rtl" role="dialog" aria-modal="true" aria-label={`حجز: ${o.title}`} ref={sheetRef}>
            <div className="grab" />
            <button type="button" className="sheet-close" onClick={() => setOpen(false)} aria-label="إغلاق">×</button>
            <div className="wrap">
              <div className="steps">{steps.map((_, i) => <i key={i} className={i <= step ? "on" : ""} />)}</div>

              {st === "slot" && (
                <>
                  <h2 tabIndex={-1}>اختر الموعد</h2>
                  <p className="hint">اختر يوماً ثم ساعة من المواعيد المتاحة. الرمادية محجوزة.</p>
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
                    </>
                  )}
                </>
              )}

              {st === "session" && (
                <>
                  <h2 tabIndex={-1}>اختر اللقاء</h2>
                  <p className="hint">كل لقاء يُحجز وحده، ويمكنك الاشتراك في كل اللقاءات القادمة إن سمح المعلم.</p>
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

              {st === "freq" && chosenAt && (
                <>
                  <h2 tabIndex={-1}>حصة واحدة أم كل أسبوع؟</h2>
                  <p className="hint">الأسبوعي يحجز لك نفس الموعد كل أسبوع تلقائياً، ويمكنك إيقافه متى شئت.</p>
                  <button className="opt" aria-pressed={!weekly} onClick={() => { setWeekly(false); setPay(null); }}>
                    <span className="dot" />
                    <span>{o.type === "group" ? "هذا اللقاء فقط" : "حصة واحدة"} <span className="muted small">· {dayLong(chosenAt)} {time(chosenAt)}</span></span>
                  </button>
                  <button className="opt" aria-pressed={weekly} onClick={() => { setWeekly(true); setPay(null); }}>
                    <span className="dot" />
                    <span>
                      {o.type === "group" ? "اشتراك في كل اللقاءات القادمة" : "موعد ثابت كل أسبوع"}
                      <span className="muted small"> · كل {dayName(chosenAt)} الساعة {time(chosenAt)}</span>
                    </span>
                  </button>
                  {weekly && (
                    <p className="note">
                      نحجز لك الأسابيع الـ{WEEKS} القادمة ونجدّدها تلقائياً. إذا كان المعلم مشغولاً في أسبوع ما نخبرك به. يمكنك إلغاء الموعد الأسبوعي في أي وقت من جدولي.
                    </p>
                  )}
                </>
              )}

              {st === "mode" && (
                <>
                  <h2 tabIndex={-1}>كيف تريد الحضور؟</h2>
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
                  <h2 tabIndex={-1}>{o.type === "course" ? "من سيسجّل؟" : o.type === "recorded" ? "لمن المحتوى؟" : "من سيحضر؟"}</h2>
                  <button className="opt" aria-pressed={who === "self"} onClick={() => { setWho("self"); setPay(null); }}>
                    <span className="dot" />
                    <span>أنا</span>
                  </button>
                  {kids.map((k) => (
                    <button key={k.id} className="opt" aria-pressed={who === k.id} onClick={() => { setWho(k.id); setPay(null); }}>
                      <span className="dot" />
                      <span>
                        {k.name} {k.grade && <span className="muted small">{k.grade}</span>}
                      </span>
                    </button>
                  ))}
                  <a className="link small" href={`/account?back=${encodeURIComponent(`/offer/${o.id}`)}#children`}>
                    إضافة ابن أو ابنة
                  </a>
                </>
              )}

              {st === "pay" && (
                <>
                  <h2 tabIndex={-1}>الدفع</h2>
                  <p className="hint">الدفع مباشرة للمعلم أو المعهد، لا يمر أي مبلغ عبر Classi.</p>
                  {canTrial && (
                    <label className="switch-row">
                      <input type="checkbox" checked={trial} onChange={(e) => { setTrial(e.target.checked); setPay(null); }} />
                      <span><b>احجزها كحصة تجريبية</b><span className="small muted">{trialPrice === 0 ? "مجانية" : `بسعر ${trialPrice} ₪`}، مرة واحدة مع هذا المعلم.</span></span>
                    </label>
                  )}
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
                          {weekly ? `كل ${dayName(chosenAt)} ${time(chosenAt)}، يبدأ ${dayLong(chosenAt)}` : `${dayLong(chosenAt)} · ${time(chosenAt)}`}
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
                      <span>{weekly ? "لكل حصة" : "المجموع"}</span>
                      <span className="num">{useTrial ? (trialPrice === 0 ? "مجانية" : `${trialPrice} ₪`) : pkg ? "من الرزمة" : `${o.price} ₪`}</span>
                    </div>
                  </div>
                  <p className="note">
                    {o.type === "private" && !o.autoConfirm
                      ? "يصل الطلب للمعلم، وتصلك رسالة عند موافقته. "
                      : o.type === "private"
                        ? "يُثبَّت الموعد فوراً دون انتظار، ويظهر رابط اللقاء أونلاين في جدولك إن وُجد. "
                        : "يصلك تأكيد في الإشعارات. "}
                    {pay === "bit" && !useTrial ? "بعد الحجز يظهر لك رقم Bit في «جدولي»: تحوّل المبلغ ثم تضغط «حوّلت المبلغ»." : pay === "cash" ? "تدفع نقداً مباشرة، والمعلم يؤكد الاستلام." : pay === "package" ? "تُخصم الحصة من رزمتك، دون دفع إضافي." : ""}
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
                  {pending ? "جارٍ الحفظ…" : step === steps.length - 1 ? (o.type === "private" && o.autoConfirm ? "تأكيد الحجز" : weekly && o.type === "private" ? "إرسال الطلب الأسبوعي" : DONE[o.type]) : "التالي"}
                </button>
              </div>
            </div>
          </div>
        </>
      )}
    </>
  );
}
