// Phone numbers and codes typed on Arabic keyboards (BUG-24).

/** Arabic-Indic (٠-٩) and Persian (۰-۹) digits -> 0-9; everything else unchanged. */
export function normalizeDigits(s: string): string {
  return String(s ?? "")
    .replace(/[\u0660-\u0669]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[\u06F0-\u06F9]/g, (d) => String(d.charCodeAt(0) - 0x06f0));
}

/** An Israeli mobile in any common form ("052-123 4567", "+972521234567", Arabic digits) -> "+972521234567", or null. */
export function toE164(raw: string): string | null {
  const d = normalizeDigits(raw).replace(/[^0-9+]/g, "");
  const m = d.match(/^(?:\+?972|0)(5\d{8})$/);
  return m ? `+972${m[1]}` : null;
}

/** Only the digits of a typed code (OTP), Arabic digits included. */
export const digitsOnly = (s: string) => normalizeDigits(s).replace(/\D/g, "");
