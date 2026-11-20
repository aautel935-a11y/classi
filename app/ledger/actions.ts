"use server";

// v3 customer payments ledger: server actions. Every write goes through a database function that checks, from the
// session, that the caller owns the business or holds the staff permission; nothing here trusts the form for that.
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { friendlyError } from "@/lib/errors";
import { safePath } from "@/lib/safe";
import { isMethod, parseAmount, parseDay } from "@/lib/ledger";
import { errParam } from "@/lib/flash";

const str = (f: FormData, k: string) => String(f.get(k) ?? "").trim();
const uuid = (s: string) => (/^[0-9a-f-]{36}$/i.test(s) ? s : null);

function back(form: FormData) {
  return safePath(str(form, "back"), "/ledger");
}
function go(to: string, q: string): never {
  const [path, hash] = to.split("#");
  redirect(`${path}${path.includes("?") ? "&" : "?"}${q}${hash ? `#${hash}` : ""}`);
}
async function signedIn() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login?next=/ledger");
  return supabase;
}
function done(to: string, error: { message?: string; code?: string } | null, ok: string): never {
  revalidatePath("/ledger");
  go(to, error ? `${errParam(friendlyError(error))}` : `ok=${ok}`);
}

export async function createChargeAction(form: FormData) {
  const supabase = await signedIn();
  const to = back(form);
  const amount = parseAmount(str(form, "amount"));
  const deposit = str(form, "deposit") ? parseAmount(str(form, "deposit")) : null;
  if (amount === null) go(to, `${errParam("اكتب مبلغاً صحيحاً أكبر من صفر.")}`);
  if (str(form, "deposit") && deposit === null) go(to, `${errParam("العربون غير صالح.")}`);
  const { error } = await supabase.rpc("create_charge", {
    p_teacher: uuid(str(form, "teacher_id")), p_institute: uuid(str(form, "institute_id")),
    p_customer_label: str(form, "customer").slice(0, 80), p_description: str(form, "description").slice(0, 200),
    p_amount: amount, p_due_on: parseDay(str(form, "due_on")), p_deposit: deposit, p_customer: null,
  });
  done(to, error, "charge");
}

export async function chargeForBookingAction(form: FormData) {
  const supabase = await signedIn();
  const to = back(form);
  const { error } = await supabase.rpc("charge_for_booking", { p_booking: uuid(str(form, "booking_id")), p_due_on: parseDay(str(form, "due_on")) });
  done(to, error, "charge");
}

export async function recordPaymentAction(form: FormData) {
  const supabase = await signedIn();
  const to = back(form);
  const amount = parseAmount(str(form, "amount"));
  const kind = str(form, "kind");
  const method = str(form, "method");
  if (amount === null) go(to, `${errParam("اكتب مبلغاً صحيحاً أكبر من صفر.")}`);
  if (!["payment", "deposit", "refund"].includes(kind) || !isMethod(method)) go(to, `${errParam("اختر النوع والطريقة.")}`);
  const { error } = await supabase.rpc("record_payment", {
    p_charge: uuid(str(form, "charge_id")), p_kind: kind, p_amount: amount, p_method: method,
    p_paid_on: parseDay(str(form, "paid_on")), p_note: str(form, "note").slice(0, 300) || null, p_allow_over: str(form, "allow_over") === "1",
  });
  done(to, error, "payment");
}

export async function voidPaymentAction(form: FormData) {
  const supabase = await signedIn();
  const { error } = await supabase.rpc("void_payment", { p_payment: uuid(str(form, "payment_id")), p_reason: str(form, "reason").slice(0, 300) });
  done(back(form), error, "void");
}

export async function adjustChargeAction(form: FormData) {
  const supabase = await signedIn();
  const to = back(form);
  const amount = parseAmount(str(form, "amount"));
  if (amount === null) go(to, `${errParam("اكتب مبلغاً صحيحاً أكبر من صفر.")}`);
  const { error } = await supabase.rpc("adjust_charge", {
    p_charge: uuid(str(form, "charge_id")), p_amount: amount, p_due_on: parseDay(str(form, "due_on")), p_reason: str(form, "reason").slice(0, 300),
  });
  done(to, error, "adjust");
}

export async function cancelChargeAction(form: FormData) {
  const supabase = await signedIn();
  const { error } = await supabase.rpc("cancel_charge", { p_charge: uuid(str(form, "charge_id")), p_reason: str(form, "reason").slice(0, 300) });
  done(back(form), error, "cancel");
}

export async function staffPermissionAction(form: FormData) {
  const supabase = await signedIn();
  const { error } = await supabase.rpc("set_staff_permission", {
    p_institute: uuid(str(form, "institute_id")), p_teacher: uuid(str(form, "teacher_id")),
    p_permission: str(form, "permission"), p_on: str(form, "on") === "1",
  });
  done(back(form), error, "staff");
}
