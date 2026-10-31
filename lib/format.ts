// Dates are stored in UTC and always shown in Israel time, with Latin digits.
export const TZ = "Asia/Jerusalem";
const L = "ar-u-nu-latn";

export const dayLong = (d: string | Date) =>
  new Intl.DateTimeFormat(L, { timeZone: TZ, weekday: "long", day: "numeric", month: "long" }).format(new Date(d));
export const dayShort = (d: string | Date) =>
  new Intl.DateTimeFormat(L, { timeZone: TZ, weekday: "short" }).format(new Date(d));
export const dayNum = (d: string | Date) =>
  new Intl.DateTimeFormat("en", { timeZone: TZ, day: "numeric" }).format(new Date(d));
export const monthName = (d: string | Date) =>
  new Intl.DateTimeFormat(L, { timeZone: TZ, month: "long" }).format(new Date(d));
export const time = (d: string | Date) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(d));
export const isoDay = (d: string | Date) =>
  new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(d));
export const weekday = (d: string | Date) =>
  ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(
    new Intl.DateTimeFormat("en-US", { timeZone: TZ, weekday: "short" }).format(new Date(d))
  );

// Israel's UTC offset at an instant, read from Intl parts (independent of the server's own time zone: BUG-21).
const PARTS = new Intl.DateTimeFormat("en-US", { timeZone: TZ, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
function offsetMinutes(at: Date) {
  const p = Object.fromEntries(PARTS.formatToParts(at).map((x) => [x.type, x.value])) as Record<string, string>;
  const asUtc = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
  return Math.round((asUtc - Math.floor(at.getTime() / 1000) * 1000) / 60000);
}
/** "2026-11-08" + "17:00" in Israel time -> Date (UTC instant). */
export function fromLocal(day: string, hhmm: string) {
  const guess = new Date(`${day}T${hhmm}:00Z`);
  const first = new Date(guess.getTime() - offsetMinutes(guess) * 60000);
  return new Date(guess.getTime() - offsetMinutes(first) * 60000);
}
export const shekel = (n: number) => `${n.toLocaleString("en")} ₪`;
export const initials = (name: string) =>
  name.replace(/^أ\.\s*/, "").split(/\s+/).slice(0, 2).map((w) => w[0]).join(" ");
