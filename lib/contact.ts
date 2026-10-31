// WhatsApp and calendar links (no external service, just URLs).
import { normalizeDigits } from "./phone";

/** "+972501234567" → https://wa.me/972501234567?text=… */
export function waLink(phone: string | null | undefined, text?: string) {
  if (!phone) return null;
  const n = phone.replace(/[^0-9]/g, "").replace(/^0/, "972");
  return `https://wa.me/${n}${text ? `?text=${encodeURIComponent(text)}` : ""}`;
}

/** "+972501234567" or "0501234567" (any form) → "+972501234567", or null. */
export function cleanMobile(raw: string) {
  const d = normalizeDigits(raw).replace(/[^0-9+]/g, "");
  return /^(\+?972|0)5\d{8}$/.test(d) ? d.replace(/^(\+?972|0)/, "+972") : null;
}

const stamp = (d: Date) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");

/** Google Calendar "add event" link. */
export function googleCalLink(title: string, startIso: string, minutes: number, details: string, location?: string) {
  const s = new Date(startIso);
  const e = new Date(s.getTime() + (minutes || 60) * 60000);
  const q = new URLSearchParams({ action: "TEMPLATE", text: title, dates: `${stamp(s)}/${stamp(e)}`, details, ...(location ? { location } : {}) });
  return `https://calendar.google.com/calendar/render?${q.toString()}`;
}

/** One or more events as an .ics file (Apple Calendar, Outlook, any phone). */
export function icsFile(events: { uid: string; title: string; start: string; minutes: number; details: string; location?: string }[]) {
  // RFC 5545 text: escape \ , ; and every kind of line break (a bare \r would start a new property).
  const esc = (t: string) => t.replace(/\\/g, "\\\\").replace(/\r\n|\r|\n/g, "\\n").replace(/[,;]/g, (m) => `\\${m}`);
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Classi//AR", "CALSCALE:GREGORIAN", "METHOD:PUBLISH"];
  for (const ev of events) {
    const s = new Date(ev.start);
    const e = new Date(s.getTime() + (ev.minutes || 60) * 60000);
    lines.push(
      "BEGIN:VEVENT", `UID:${ev.uid}@classi`, `DTSTAMP:${stamp(new Date())}`, `DTSTART:${stamp(s)}`, `DTEND:${stamp(e)}`,
      `SUMMARY:${esc(ev.title)}`, `DESCRIPTION:${esc(ev.details)}`, ...(ev.location ? [`LOCATION:${esc(ev.location)}`] : []),
      "BEGIN:VALARM", "TRIGGER:-PT1H", "ACTION:DISPLAY", `DESCRIPTION:${esc(ev.title)}`, "END:VALARM",
      "END:VEVENT",
    );
  }
  lines.push("END:VCALENDAR");
  return lines.map(foldIcsLine).join("\r\n");
}

/** RFC 5545 §3.1: lines longer than 75 octets continue on the next line after CRLF + space (never splitting a character). */
export function foldIcsLine(line: string): string {
  const enc = new TextEncoder();
  if (enc.encode(line).length <= 75) return line;
  const parts: string[] = [];
  let cur = "", size = 0, limit = 75;
  for (const ch of line) {
    const n = enc.encode(ch).length;
    if (size + n > limit) { parts.push(cur); cur = ""; size = 0; limit = 74; }
    cur += ch; size += n;
  }
  parts.push(cur);
  return parts.join("\r\n ");
}
