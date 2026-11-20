import { flashText } from "@/lib/flash";

/** The red message box for "?error=": only text the server signed is shown (SEC-26, lib/flash.ts). */
export function ErrorNote({ msg }: { msg?: string | null }) {
  const t = flashText(msg);
  return t ? <p className="err" role="alert">{t}</p> : null;
}
