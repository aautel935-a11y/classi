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
export function nextDays(n: number, from = new Date(), startToday = false) {
  // Every day of the week, Saturday included (BUG-01): a teacher who opens Saturday hours gets Saturday bookings.
  const out: string[] = [];
  const d = new Date(`${isoDay(from)}T12:00:00Z`);
  if (!startToday) d.setUTCDate(d.getUTCDate() + 1);
  while (out.length < n) {
    out.push(d.toISOString().slice(0, 10));
    d.setUTCDate(d.getUTCDate() + 1);
  }
  return out;
}

export const WEEKDAYS = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];

export type Slot = { day: string; time: string; at: string; busy: boolean };

/** Private-lesson slots from weekly availability, minus busy times. */
export function privateSlots(
  availability: { weekday: number; start_time: string; end_time: string }[],
  busy: { starts_at: string; minutes: number }[],
  minutes: number,
  days = nextDays(8, new Date(), true),
  bufferMinutes = 0
): Slot[] {
  const now = Date.now();
  const slots: Slot[] = [];
  for (const day of days) {
    const wd = new Date(`${day}T12:00:00Z`).getUTCDay();
    const dayStart = fromLocal(day, "00:00").getTime();
    const hhmm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
    const buf = bufferMinutes * 60000;
    // Lesson + break apart (45 + 15 = every hour; 90 = 16:00, 17:30, 19:00). When a time is taken, the next
    // offer starts right when that booking (and its break) ends, so long lessons never overlap or waste time.
    const step = minutes + bufferMinutes;
    for (const a of availability.filter((x) => x.weekday === wd).sort((x, y) => x.start_time.localeCompare(y.start_time))) {
      const [sh, sm] = a.start_time.split(":").map(Number);
      const [eh, em] = a.end_time.split(":").map(Number);
      const to = eh * 60 + em;
      let m = sh * 60 + sm;
      while (m + minutes <= to) {
        const time = hhmm(m);
        const start = fromLocal(day, time).getTime();
        const end = start + minutes * 60000;
        const hits = busy.filter((x) => {
          const bs = new Date(x.starts_at).getTime();
          return bs - buf < end && bs + x.minutes * 60000 + buf > start;
        });
        slots.push({ day, time, at: new Date(start).toISOString(), busy: hits.length > 0 || start < now + 2 * 3600000 });
        if (hits.length === 0) { m += step; continue; }
        const freeAt = Math.max(...hits.map((x) => new Date(x.starts_at).getTime() + x.minutes * 60000 + buf));
        m = Math.max(m + 5, Math.ceil((freeAt - dayStart) / 60000 / 5) * 5);
      }
    }
  }
  return slots;
}

export { TZ };
