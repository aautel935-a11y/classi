import { createClient } from "@/lib/supabase/server";

type Access = { kind: "teacher" | "institute"; business_id: string; state: string; ends_at: string | null; days_left: number | null;
  trial_ends_at: string | null; paid_until: string | null; required: boolean; grace_days: number };

const dmy = (d: string) => new Date(d).toLocaleDateString("ar-u-nu-latn", { timeZone: "Asia/Jerusalem", day: "numeric", month: "long", year: "numeric" });
const days = (n: number) => `${n} ${n === 1 ? "يوم" : "أيام"}`;

/** Business owner: free-trial, grace and exemption state (v3). Says nothing for an active subscription (SubscriptionBox does). */
export async function AccessBanner({ kind, id }: { kind: "teacher" | "institute"; id: string }) {
  const supabase = await createClient();
  const { data } = await supabase.rpc("my_access_state");
  const a = ((data ?? []) as Access[]).find((x) => x.kind === kind && x.business_id === id);
  if (!a || !a.ends_at || a.days_left === null) return null;
  if (a.state === "trial") {
    return (
      <p className={a.days_left <= 7 ? "note sub-warn" : "note"}>
        تجربتك المجانية في Classi حتى {dmy(a.ends_at)} (بقي {days(a.days_left)}).
        {a.required ? " بعدها تحتاج باقة حتى تبقى ظاهراً للزبائن." : " اختر باقة متى شئت، وتبدأ مدتها بعد التفعيل."} بياناتك لا تُحذف أبداً عند الانتهاء.
      </p>
    );
  }
  if (a.state === "grace") {
    return (
      <p className="note sub-warn">
        انتهت فترتك. أنت في فترة سماح حتى {dmy(a.ends_at)} (بقي {days(a.days_left)}) وما زلت ظاهراً للزبائن. جدّد الاشتراك لتستمر؛ بياناتك محفوظة في كل الأحوال.
      </p>
    );
  }
  if (a.state === "exempt") return <p className="note">حسابك معفى من الاشتراك حتى {dmy(a.ends_at)}.</p>;
  return null;
}
