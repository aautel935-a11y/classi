"use server";

// v3 business access, admin side: extend a trial, set or revoke an exemption, discount an open subscription request.
// Each database function checks is_admin() itself and writes the audit log.
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { friendlyError } from "@/lib/errors";
import { parseDay } from "@/lib/ledger";
import { errParam } from "@/lib/flash";

const str = (f: FormData, k: string) => String(f.get(k) ?? "").trim();
const uuid = (s: string) => (/^[0-9a-f-]{36}$/i.test(s) ? s : null);
const BACK = "/admin?tab=subs";

function done(error: { message?: string; code?: string } | null, ok: string): never {
  revalidatePath("/admin");
  redirect(`${BACK}&${error ? `${errParam(friendlyError(error))}` : `done=${ok}`}#access`);
}
function owner(form: FormData) {
  const kind = str(form, "kind"), id = uuid(str(form, "business_id"));
  return { p_teacher: kind === "teacher" ? id : null, p_institute: kind === "institute" ? id : null };
}

export async function adminAccessAction(form: FormData) {
  const supabase = await createClient();
  const op = str(form, "op");
  if (op === "extend") {
    const { error } = await supabase.rpc("admin_extend_trial", { ...owner(form), p_days: Number(str(form, "days")) || 0, p_reason: str(form, "reason") });
    done(error, "trial");
  }
  if (op === "exempt") {
    const until = str(form, "until") ? parseDay(str(form, "until")) : null;
    if (str(form, "until") && !until) done({ message: "تاريخ غير صالح" }, "");
    const { error } = await supabase.rpc("admin_set_exemption", { ...owner(form), p_until: until, p_reason: str(form, "reason") });
    done(error, "exempt");
  }
  if (op === "discount") {
    const { error } = await supabase.rpc("admin_discount_request", {
      p_id: uuid(str(form, "request_id")), p_price: Math.round(Number(str(form, "price"))), p_reason: str(form, "reason"),
    });
    done(error, "discount");
  }
  done({ message: "عملية غير معروفة" }, "");
}
