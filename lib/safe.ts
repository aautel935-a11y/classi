// Guards for values that come from the address bar or a form and end up in a redirect or on screen.
// Pure functions: usable in server actions, route handlers and client components.

/**
 * A same-site path, or the fallback. Rejects anything a browser could resolve to another site:
 * "//evil.com", "/\evil.com", "https://…", control characters (e.g. "/\t/evil.com"), or no leading "/".
 */
export function safePath(p: string | null | undefined, fallback = "/"): string {
  const s = String(p ?? "");
  if (!s.startsWith("/") || s.length > 512) return fallback;
  if (s[1] === "/" || s[1] === "\\") return fallback;
  if (/[\u0000-\u001f\u007f\\]/.test(s)) return fallback;
  return s;
}

/** Add "?q" or "&q" to a path, whichever fits. */
export function withQuery(url: string, q: string): string {
  return url + (url.includes("?") ? "&" : "?") + q;
}

const GENERIC = "تعذّر إتمام العملية. حاول مرة أخرى.";

/**
 * Text from "?error=" shown on a page. Anyone can craft such a link, so text that could carry a phishing lure
 * (a web address, an email, a phone or account number) or an over-long message is replaced by a generic one.
 */
export function errorText(e: string | null | undefined): string | null {
  const s = String(e ?? "").trim();
  if (!s) return null;
  if (s.length > 220) return GENERIC;
  if (/https?:|www\.|@|\b[a-z0-9-]+\.(com|net|org|co|il|io|me|app|click|info|xyz|ly|to|link)\b/i.test(s)) return GENERIC;
  const digits = s.replace(/[\s\-–.()+]/g, "");
  if (/\d{7,}|[٠-٩]{7,}/.test(digits)) return GENERIC;
  return s;
}
