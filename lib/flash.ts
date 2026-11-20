// SERVER ONLY (node:crypto). Error messages that travel in "?error=" are SIGNED (SEC-26): the server writes
// "error=<tag>.<text>" and pages show the text only when the tag is the server's own. A link someone else crafted
// ("?error=رسالة مزيفة") can therefore never put words on a Classi page: it shows a generic line instead.
// No new secret: the key is derived from a server-only secret the deployment already has (production: the 019/Resend
// tokens; staging: the 019 test token; FLASH_SECRET overrides). Never the service key: only lib/supabase/worker.ts reads
// it. Without any (local dev, CI) a random per-process key is used, which only means a message signed by another
// process shows the generic line.
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { errorText } from "./safe";

export const FLASH_GENERIC = "تعذّر إتمام العملية. حاول مرة أخرى.";

const source = process.env.FLASH_SECRET || process.env.SMS_019_TOKEN || process.env.RESEND_API_KEY || process.env.SMS_019_TEST;
const KEY = createHmac("sha256", "classi-flash-v1").update(source ? source : randomBytes(32)).digest();

function tag(text: string): string {
  return createHmac("sha256", KEY).update(text, "utf8").digest("base64url").slice(0, 22);
}

/** The query part for an error redirect: `error=<tag>.<text>`, URL-encoded. Use instead of `error=${...}`. */
export function errParam(text: string): string {
  const t = String(text ?? "").slice(0, 300);
  return `error=${encodeURIComponent(`${tag(t)}.${t}`)}`;
}

/** The text a page may show for a "?error=" value: the signed text (screened again by errorText), or the generic line
 *  for anything unsigned or tampered with; null when there is no error. */
export function flashText(param: string | string[] | null | undefined): string | null {
  const p = Array.isArray(param) ? param[0] : param;
  if (!p) return null;
  const dot = p.indexOf(".");
  if (dot === 22) {
    const t = p.slice(23), given = Buffer.from(p.slice(0, 22)), want = Buffer.from(tag(t));
    if (given.length === want.length && timingSafeEqual(given, want)) return errorText(t) ?? FLASH_GENERIC;
  }
  return FLASH_GENERIC;
}
