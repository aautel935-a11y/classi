import { Icon } from "@/components/Icon";
import { BitCopy } from "@/components/BitCopy";
import { reportSubscriptionAction, requestSubscriptionAction } from "@/app/actions";
import { shekel } from "@/lib/format";

export type Plan = { code: string; name: string; months: number; price: number; active: boolean };
export type SubRequest = { id: string; status: string; price: number; months: number } | null;

const date = (d: string) => new Date(d).toLocaleDateString("ar-u-nu-latn", { timeZone: "Asia/Jerusalem", day: "numeric", month: "long", year: "numeric" });

/** The teacher's/institute's subscription: status, plans, and paying the platform by Bit. */
export function SubscriptionBox({ required, paidUntil, plans, request, platformBit, back, flash, hasAccountOffers }: {
  required: boolean; paidUntil: string | null; plans: Plan[]; request: SubRequest; platformBit: string; back: string; flash?: string; hasAccountOffers: boolean;
}) {
  const active = !!paidUntil && new Date(paidUntil) > new Date();
  const daysLeft = active ? Math.ceil((new Date(paidUntil!).getTime() - Date.now()) / 864e5) : 0;
  const monthly = plans.find((p) => p.months === 1)?.price ?? 0;
  return (
    <section className="section" id="subscription">
      <h2>اشتراكي في Classi</h2>
      {flash === "chosen" && <p className="okmsg">اخترت الباقة. حوّل المبلغ عبر Bit ثم اضغط «حوّلت المبلغ».</p>}
      {flash === "reported" && <p className="okmsg">أبلغنا الإدارة بالتحويل. يتفعّل الاشتراك بعد التأكد، ويصلك إشعار.</p>}
      <div className={`card ${active ? "" : required ? "sub-warn" : ""}`}>
        {active ? (
          <>
            <b><Icon name="check" /> الاشتراك فعّال حتى {date(paidUntil!)}</b>
            <span className="small muted">{daysLeft <= 7 ? `بقي ${daysLeft} ${daysLeft === 1 ? "يوم" : "أيام"}. جدّد الآن حتى لا تتوقف عروضك.` : "عروضك ظاهرة للطلاب. يمكنك التجديد مسبقاً، وتُضاف المدة لنهاية اشتراكك."}</span>
          </>
        ) : required ? (
          <>
            <b>لا يوجد اشتراك فعّال</b>
            <span className="small">{hasAccountOffers ? "عروضك وملفك لا يظهران للطلاب حتى تفعّل اشتراكاً." : "فعّل اشتراكاً ليظهر ملفك وعروضك للطلاب."}</span>
          </>
        ) : (
          <>
            <b>فترة الإطلاق: النشر مجاني حالياً</b>
            <span className="small muted">عند انتهاء فترة الإطلاق يصبح الظهور للطلاب باشتراك. يمكنك الاشتراك مسبقاً، وتبدأ المدة من يوم التفعيل.</span>
          </>
        )}
      </div>

      {request ? (
        <div className="card paybox">
          <b>طلب اشتراك {request.months === 12 ? "سنة" : `${request.months} ${request.months === 1 ? "شهر" : "أشهر"}`} · {shekel(request.price)}</b>
          {request.status === "reported" ? (
            <span className="small"><Icon name="clock" /> بانتظار تأكيد الإدارة لاستلام التحويل.</span>
          ) : (
            <>
              {platformBit ? (
                <>
                  <span className="small">حوّل {shekel(request.price)} عبر Bit إلى Classi:</span>
                  <BitCopy phone={platformBit} />
                </>
              ) : (
                <span className="small muted">رقم Bit للدفع لم يُضف بعد. راسل الإدارة: classi@torix.click</span>
              )}
              <form action={reportSubscriptionAction}>
                <input type="hidden" name="id" value={request.id} />
                <input type="hidden" name="back" value={back} />
                <button className="btn sm okb">حوّلت المبلغ</button>
              </form>
            </>
          )}
        </div>
      ) : null}

      {request?.status !== "reported" && (
        <div className="plans">
          {plans.filter((p) => p.active).map((p) => {
            const perMonth = Math.round(p.price / p.months);
            const save = monthly ? monthly * p.months - p.price : 0;
            return (
              <form key={p.code} action={requestSubscriptionAction} className={`plan ${p.months === 12 ? "best" : ""}`}>
                <input type="hidden" name="plan" value={p.code} />
                <input type="hidden" name="back" value={back} />
                {p.months === 12 && <span className="badge ok">الأوفر</span>}
                <b>{p.name}</b>
                <span className="price num">{shekel(p.price)}</span>
                <span className="small muted num">{p.months > 1 ? `${perMonth} ₪ للشهر` : "شهرياً"}{save > 0 ? ` · توفير ${save} ₪` : ""}</span>
                <button className="btn sm">{request?.status === "pending" ? "اختيار هذه بدلاً" : active ? "تجديد" : "اشترك"}</button>
              </form>
            );
          })}
        </div>
      )}
    </section>
  );
}
