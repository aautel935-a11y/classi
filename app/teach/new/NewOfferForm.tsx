"use client";

import { OfferExtras } from "@/components/OfferExtras";
import { useState } from "react";
import { Icon } from "@/components/Icon";
import { newOfferingAction } from "@/app/actions";
import { TYPES, type OfferingType } from "@/lib/types";

const DAYS = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة"];
type Opt = { id: number; name: string };

export function NewOfferForm({ subjects, levels, error }: { subjects: Opt[]; levels: Opt[]; error?: string }) {
  const [tp, setTp] = useState<Exclude<OfferingType, "course">>("private");
  const [place, setPlace] = useState("home");
  const online = tp === "recorded" || place === "online" || place === "both";
  return (
    <form action={newOfferingAction} className="section">
      <h1>عرض جديد</h1>
      <p className="small muted">اختر النوع أولاً، والحقول تتغير حسبه. دورات المعاهد تُنشر من حساب المعهد.</p>
      {error && <p className="err">{error}</p>}
      <input type="hidden" name="type" value={tp} />
      <div className="types">
        {(["private", "group", "recorded"] as const).map((k) => (
          <button
            key={k}
            type="button"
            className="type"
            aria-pressed={k === tp}
            onClick={() => setTp(k)}
            style={k === tp ? { borderColor: "var(--primary)", boxShadow: "inset 0 0 0 1px var(--primary)" } : undefined}
          >
            <span className="ico"><Icon name={TYPES[k].icon} /></span>
            <b>{TYPES[k].name}</b>
            <span>{TYPES[k].desc}</span>
          </button>
        ))}
      </div>
      <label className="field" htmlFor="title">
        العنوان
        <input id="title" name="title" required minLength={3} placeholder={tp === "group" ? "مجموعة تقوية رياضيات، صف 11" : tp === "recorded" ? "شرح المتتاليات كاملاً" : "رياضيات 4 وحدات"} />
      </label>
      <div className="typeform">
        <label className="field" htmlFor="subject_id">المادة<select id="subject_id" name="subject_id">{subjects.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
        <label className="field" htmlFor="level_id">المرحلة<select id="level_id" name="level_id" defaultValue={levels.find((l) => l.name === "ثانوي")?.id}>{levels.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
        <label className="field" htmlFor="price">
          {tp === "private" ? "السعر للحصة (₪)" : tp === "group" ? "السعر للطالب في اللقاء (₪)" : "السعر (₪)"}
          <input id="price" name="price" type="number" min={0} required defaultValue={tp === "private" ? 150 : tp === "group" ? 60 : 149} />
        </label>
        {tp !== "recorded" && (
          <label className="field" htmlFor="minutes">
            مدة {tp === "private" ? "الحصة" : "اللقاء"}
            <select id="minutes" name="minutes" defaultValue={tp === "private" ? "60" : "90"}>
              {(tp === "private" ? [30, 45, 60, 90, 120] : [45, 60, 90, 120, 150]).map((m) => <option key={m} value={m}>{m === 60 ? "ساعة" : m === 90 ? "ساعة ونصف" : m === 120 ? "ساعتان" : `${m} دقيقة`}</option>)}
            </select>
          </label>
        )}
        {tp !== "recorded" && (
          <label className="field" htmlFor="place">
            المكان
            <select id="place" name="place" value={place} onChange={(e) => setPlace(e.target.value)}>
              <option value="home">حضوري</option>
              <option value="online">أونلاين</option>
              {tp === "private" && <option value="both">الاثنان</option>}
            </select>
          </label>
        )}
        {tp === "group" && (
          <>
            <label className="field" htmlFor="seats">عدد المقاعد<input id="seats" name="seats" type="number" min={2} max={30} defaultValue={6} /></label>
            <label className="field" htmlFor="weekday">اليوم<select id="weekday" name="weekday">{DAYS.map((d, i) => <option key={d} value={i}>{d}</option>)}</select></label>
            <label className="field" htmlFor="time">الساعة<input id="time" name="time" type="time" defaultValue="18:00" /></label>
          </>
        )}
        {tp === "recorded" && (
          <label className="field" htmlFor="lessons">عدد الدروس<input id="lessons" name="lessons" type="number" min={1} defaultValue={12} /></label>
        )}
      </div>
      {online && (
        <label className="field" htmlFor="link">
          {tp === "recorded" ? "رابط المحتوى (YouTube غير مُدرج أو Google Drive)" : "رابط زوم أو Google Meet الثابت"}
          <input id="link" name="link" type="url" dir="ltr" placeholder={tp === "recorded" ? "https://drive.google.com/…" : "https://zoom.us/j/…"} />
          <span className="small muted">لا يظهر للعامة. يراه الطالب في جدوله بعد تأكيد الحجز. يمكنك إضافته أو تغييره لاحقاً.</span>
        </label>
      )}
      {(tp === "private" || tp === "group") && (
        <fieldset className="card">
          <legend>طريقة الحجز</legend>
          {tp === "private" && (
            <label className="switch-row">
              <input type="checkbox" name="auto_confirm" />
              <span><b>تأكيد فوري</b><span className="small muted">يُثبَّت الحجز مباشرة دون انتظار موافقتك. اتركه مغلقاً لتوافق على كل طلب بنفسك.</span></span>
            </label>
          )}
          <label className="switch-row">
            <input type="checkbox" name="allow_weekly" />
            <span><b>السماح بالحجز الأسبوعي</b><span className="small muted">{tp === "group" ? "يستطيع الطالب الاشتراك في كل اللقاءات القادمة مرة واحدة." : "يستطيع الطالب تثبيت نفس الموعد كل أسبوع."}</span></span>
          </label>
        </fieldset>
      )}
      <OfferExtras type={tp} />
      {tp === "group" && <p className="note"><Icon name="cal" />ننشئ لقاءات الأسابيع الثمانية القادمة تلقائياً.</p>}
      {tp === "private" && <p className="note"><Icon name="clock" />أوقاتك المتاحة الافتراضية: الأحد إلى الخميس 15:00 إلى 21:00.</p>}
      <button className="btn block">نشر العرض</button>
    </form>
  );
}
