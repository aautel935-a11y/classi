// One place that turns database and network errors into Arabic text for the user (BUG-23).
// Messages raised by Classi's own database functions are already Arabic and pass through unchanged.

type Err = { code?: string; message?: string } | null | undefined;

export function friendlyError(e: Err): string {
  if (!e) return "";
  const msg = String(e.message ?? "");
  if (/[\u0600-\u06FF]/.test(msg) && !/violates|duplicate key|permission denied/i.test(msg)) return msg;
  switch (e.code) {
    case "42501": return "لا تملك صلاحية لهذه العملية.";
    case "23505": return "هذا موجود سابقاً.";
    case "23514": return "بعض القيم غير صالحة. راجع الحقول وحاول مرة أخرى.";
    case "23503": return "لا يمكن إتمام العملية لأنها مرتبطة ببيانات أخرى.";
    case "22P02": case "22007": case "22008": return "صيغة إحدى القيم غير صحيحة.";
  }
  if (/row-level security|permission denied/i.test(msg)) return "لا تملك صلاحية لهذه العملية.";
  if (/fetch failed|network|timeout|ECONN|Failed to fetch/i.test(msg)) return "تعذّر الاتصال. تحقق من الإنترنت وحاول مرة أخرى.";
  // Unknown error: keep the technical detail in the server log (code and message only, never request data).
  if (typeof window === "undefined") console.error("[unmapped error]", e.code ?? "", msg.slice(0, 300));
  return "تعذّر إتمام العملية. حاول مرة أخرى.";
}
