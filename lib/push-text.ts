// D-08 / TM-12: a Web Push notification is shown on the lock screen, where anyone near the phone can read it. It carries
// a short neutral line by kind, never the notification body (names, times, subjects, message text, amounts); the details
// open inside Classi after the tap (/n/<id>). Email and SMS keep their full text (they go to the account's own inbox/phone).

const GROUPS: [RegExp, string][] = [
  [/^reminder/, "تذكير بموعد قادم في Classi"],
  [/^message$/, "وصلتك رسالة جديدة في Classi"],
  [/^(booking_|schedule_changed$|waitlist_|link_)/, "تحديث على حجوزاتك في Classi"],
  [/^(lesson_report$|report_due$)/, "تحديث على تقارير الحصص في Classi"],
  [/^payment_/, "تحديث على الدفعات في Classi"],
  [/^staff_/, "تحديث من طاقم المعهد في Classi"],
];

/** Neutral push text for a notification kind (no personal details). */
export function pushText(kind: string): string {
  for (const [re, text] of GROUPS) if (re.test(kind ?? "")) return text;
  return "لديك إشعار جديد في Classi";
}

/** The JSON a push carries: title, neutral body, the in-app link and a tag for reminders. */
export function pushPayload(it: { id: string; kind: string }): string {
  return JSON.stringify({
    title: "Classi",
    body: pushText(it.kind),
    url: `/n/${it.id}`,
    tag: (it.kind ?? "").startsWith("reminder") ? `r-${it.id}` : undefined,
  });
}
