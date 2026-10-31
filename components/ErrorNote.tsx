import { errorText } from "@/lib/safe";

/** The red message box for "?error=" (text is screened by errorText). */
export function ErrorNote({ msg }: { msg?: string | null }) {
  const t = errorText(msg);
  return t ? <p className="err" role="alert">{t}</p> : null;
}
