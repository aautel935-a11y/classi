/** The 6-digit code inside the SMS text (D-08 / TM-14: the database no longer keeps it in a separate column). */
export function codeFromBody(body: string): string | null {
  const m = /(^|\D)(\d{6})(\D|$)/.exec(body ?? "");
  return m ? m[2] : null;
}
