import { TZ, fromLocal, isoDay } from "./format";

/** The next `count` dates (Israel calendar) from `startDay` that fall on one of `weekdays` (0 = Sunday). */
export function datesOn(startDay: string, weekdays: number[], count: number) {
  const out: string[] = [];
  const d = new Date(`${startDay}T12:00:00Z`);
  for (let i = 0; out.length < count && i < 400; i++) {
    if (weekdays.includes(d.getUTCDay())) out.push(d.toISOString().slice(0, 10));
    d.setUTCDate(d.getUTCDate() + 1);
  }
  return out;
}

/** Next `n` calendar days in Israel, skipping Saturday. */
export function nextDays(n: number, from = new Date()) {
  const out: string[] = [];
  const d = new Date(`${isoDay(from)}T12:00:00Z`);
  while (out.length < n) {
    d.setUTCDate(d.getUTCDate() + 1);
    if (d.getUTCDay() !== 6) out.push(d.toISOString().slice(0, 10));
  }
  return out;
}

export const WEEKDAYS = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];

export type Slot = { day: string; time: string; at: string; busy: boolean };

/** Hourly private-lesson slots from weekly availability, minus busy times. */
export function privateSlots(
  availability: { weekday: number; start_time: string; end_time: string }[],
  busy: { starts_at: string; minutes: number }[],
  minutes: number,
  days = nextDays(7)
): Slot[] {
  const now = Date.now();
  const slots: Slot[] = [];
  for (const day of days) {
    const wd = new Date(`${day}T12:00:00Z`).getUTCDay();
    for (const a of availability.filter((x) => x.weekday === wd)) {
      const [sh, sm] = a.start_time.split(":").map(Number);
      const [eh, em] = a.end_time.split(":").map(Number);
      for (let m = sh * 60 + sm; m + minutes <= eh * 60 + em; m += 60) {
        const time = `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
        const start = fromLocal(day, time).getTime();
        const end = start + minutes * 60000;
        const clash = busy.some((b) => {
          const bs = new Date(b.starts_at).getTime();
          return bs < end && bs + b.minutes * 60000 > start;
        });
        slots.push({ day, time, at: new Date(start).toISOString(), busy: clash || start < now + 2 * 3600000 });
      }
    }
  }
  return slots;
}

export { TZ };
