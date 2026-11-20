// v3 customer payments ledger: labels, input parsing and CSV export. Pure functions (server, client and unit tests).
// Classi only RECORDS payments the business received outside the app; it never moves or holds money.

export type ChargeStatus = "unpaid" | "partial" | "paid" | "overdue" | "cancelled";
export type EntryKind = "payment" | "deposit" | "refund" | "void";
export type PayMethod = "cash" | "bit" | "paybox" | "bank_transfer" | "cheque" | "other";

export type ChargeRow = {
  id: string; customer_label: string; customer_id: string | null; description: string; source_kind: string; source_id: string | null;
  amount: number; deposit_amount: number | null; paid: number; remaining: number; status: ChargeStatus; due_on: string | null;
  created_at: string; cancel_reason: string | null;
};
export type EntryRow = {
  id: string; kind: EntryKind; amount: number; method: PayMethod | null; paid_on: string | null; note: string | null;
  voids: string | null; voided: boolean; recorded_by_name: string | null; recorded_at: string;
};
export type MyChargeRow = {
  id: string; business_name: string; description: string; amount: number; paid: number; remaining: number;
  status: ChargeStatus; due_on: string | null; created_at: string;
};

/** Shown wherever a payment status is shown to a customer, and in every export (decision of 19/11/2026). */
export const LEDGER_NOTICE = "هذه الحالة مسجّلة من صاحب العمل. Classi لا يستلم الأموال ولا يؤكد وصولها، وهذا ليس مستنداً ضريبياً.";

export const STATUS_LABEL: Record<ChargeStatus, string> = {
  unpaid: "غير مدفوع", partial: "مدفوع جزئياً", paid: "مدفوع", overdue: "متأخر", cancelled: "ملغى",
};
export const METHOD_LABEL: Record<PayMethod, string> = {
  cash: "نقداً", bit: "Bit", paybox: "PayBox", bank_transfer: "تحويل بنكي", cheque: "شيك", other: "أخرى",
};
export const KIND_LABEL: Record<EntryKind, string> = { payment: "دفعة", deposit: "عربون", refund: "استرداد", void: "تصحيح (إلغاء دفعة)" };
export const METHODS = Object.keys(METHOD_LABEL) as PayMethod[];
export const STATUSES = Object.keys(STATUS_LABEL) as ChargeStatus[];

export const isStatus = (s: unknown): s is ChargeStatus => typeof s === "string" && (STATUSES as string[]).includes(s);
export const isMethod = (s: unknown): s is PayMethod => typeof s === "string" && (METHODS as string[]).includes(s);

/**
 * An amount typed by a person: "150", "150.5", "1,250.75", "₪ 90". Returns null when it is not a positive amount with at most
 * two decimals, or above one million. Commas are thousands separators only when followed by exactly three digits.
 */
export function parseAmount(input: unknown): number | null {
  let s = String(input ?? "").replace(/[₪\s]/g, "");
  if (/^\d{1,3}(,\d{3})+(\.\d{1,2})?$/.test(s)) s = s.replace(/,/g, "");
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null;
  const n = Number(s);
  return n > 0 && n <= 1_000_000 ? Math.round(n * 100) / 100 : null;
}

/** "YYYY-MM-DD" or null. */
export function parseDay(input: unknown): string | null {
  const s = String(input ?? "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const d = new Date(`${s}T00:00:00Z`);
  return Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== s ? null : s;
}

/** 1250.5 → "1,250.50 ₪" (two decimals only when needed). */
export function money(n: number): string {
  const v = Math.round(Number(n) * 100) / 100;
  return `${v.toLocaleString("en", { minimumFractionDigits: Number.isInteger(v) ? 0 : 2, maximumFractionDigits: 2 })} ₪`;
}

/**
 * One CSV cell. Quoted always; a cell that a spreadsheet would run as a formula (starting with = + - @, tab or CR) gets a
 * leading apostrophe, so an exported customer name cannot become a formula (CSV injection).
 */
export function csvCell(v: unknown): string {
  let s = v === null || v === undefined ? "" : String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return `"${s.replace(/"/g, '""')}"`;
}

export function csvRows(rows: unknown[][]): string {
  return rows.map((r) => r.map(csvCell).join(",")).join("\r\n");
}

/** A timestamp as its Israeli calendar day (YYYY-MM-DD). */
export const ilDay = (ts: string) => new Date(ts).toLocaleDateString("en-CA", { timeZone: "Asia/Jerusalem" });

/** The business's charges as CSV for the accountant: a UTF-8 BOM (Excel shows Arabic), the notice, then one row per charge. */
export function chargesCsv(rows: ChargeRow[]): string {
  const head = ["الزبون", "الوصف", "المبلغ", "العربون", "المدفوع", "المتبقي", "الحالة", "تاريخ الاستحقاق", "أُنشئ", "سبب الإلغاء"];
  const body = rows.map((r) => [
    r.customer_label, r.description, r.amount, r.deposit_amount ?? "", r.paid, r.remaining, STATUS_LABEL[r.status] ?? r.status,
    r.due_on ?? "", ilDay(r.created_at), r.cancel_reason ?? "",
  ]);
  return "﻿" + csvRows([[LEDGER_NOTICE], head, ...body]) + "\r\n";
}

/** Totals over a list of charges (cancelled ones excluded from what is owed). */
export function totals(rows: Pick<ChargeRow, "amount" | "paid" | "remaining" | "status">[]) {
  const live = rows.filter((r) => r.status !== "cancelled");
  const sum = (xs: number[]) => Math.round(xs.reduce((a, b) => a + Number(b), 0) * 100) / 100;
  return {
    charged: sum(live.map((r) => r.amount)),
    paid: sum(live.map((r) => r.paid)),
    remaining: sum(live.map((r) => r.remaining)),
    overdue: sum(live.filter((r) => r.status === "overdue").map((r) => r.remaining)),
    open: live.filter((r) => r.remaining > 0).length,
  };
}

const STATUS_ORDER: Record<ChargeStatus, number> = { overdue: 0, partial: 1, unpaid: 2, paid: 3, cancelled: 4 };

/** The list order an owner works through: overdue first, then partly paid, unpaid (earliest due date first, then
 *  newest), paid, cancelled. Stable for equal keys. */
export function sortCharges<T extends Pick<ChargeRow, "status" | "due_on" | "created_at">>(rows: T[]): T[] {
  return rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) =>
      (STATUS_ORDER[a.r.status] ?? 9) - (STATUS_ORDER[b.r.status] ?? 9)
      || (a.r.due_on ?? "9999").localeCompare(b.r.due_on ?? "9999")
      || b.r.created_at.localeCompare(a.r.created_at)
      || a.i - b.i)
    .map((x) => x.r);
}

/** Arabic-insensitive text match for the ledger search box (customer or description): alef forms, ta marbuta,
 *  alef maqsura, diacritics and tatweel are folded; case is ignored. */
export function foldArabic(s: string): string {
  return s.toLowerCase()
    .replace(/[ً-ْٰـ]/g, "")
    .replace(/[أإآٱ]/g, "ا").replace(/ة/g, "ه").replace(/ى/g, "ي")
    .replace(/\s+/g, " ").trim();
}
export function matchCharge(r: Pick<ChargeRow, "customer_label" | "description">, q: string | null | undefined): boolean {
  const n = foldArabic(String(q ?? "")).slice(0, 80);
  if (!n) return true;
  return foldArabic(`${r.customer_label} ${r.description}`).includes(n);
}

/** Customer: what is still owed across businesses (cancelled excluded). */
export function owedTotal(rows: Pick<MyChargeRow, "remaining" | "status">[]): number {
  return Math.round(rows.filter((r) => r.status !== "cancelled").reduce((a, r) => a + Number(r.remaining), 0) * 100) / 100;
}
