import type { OfferingType } from "@/lib/types";

/** Optional extras a teacher switches on per offer: a trial lesson and lesson packages. */
export function OfferExtras({ type, trialPrice, packageOn, packageSize, packagePrice }: {
  type: OfferingType; trialPrice?: number | null; packageOn?: boolean; packageSize?: number | null; packagePrice?: number | null;
}) {
  if (type !== "private" && type !== "group") return null;
  return (
    <fieldset className="card">
      <legend>عروض اختيارية</legend>
      {type === "private" && (
        <div className="toggle-group">
          <label className="switch-row">
            <input type="checkbox" name="trial_on" defaultChecked={trialPrice != null} />
            <span><b>حصة تجريبية</b><span className="small muted">أول حصة لكل طالب جديد مجاناً أو بسعر مخفّض. مرة واحدة لكل طالب.</span></span>
          </label>
          <label className="field sub">
            سعر الحصة التجريبية (₪، 0 = مجانية)
            <input name="trial_price" type="number" min={0} defaultValue={trialPrice ?? 0} />
          </label>
        </div>
      )}
      <div className="toggle-group">
        <label className="switch-row">
          <input type="checkbox" name="package_on" defaultChecked={!!packageOn} />
          <span><b>رزمة حصص</b><span className="small muted">مثلاً 10 حصص بسعر أقل. كل حجز يُخصم من الرزمة تلقائياً، والحصة الملغاة ترجع إليها.</span></span>
        </label>
        <div className="typeform sub">
          <label className="field">عدد الحصص<input name="package_size" type="number" min={2} max={50} defaultValue={packageSize ?? 10} /></label>
          <label className="field">سعر الرزمة كاملة (₪)<input name="package_price" type="number" min={0} defaultValue={packagePrice ?? ""} placeholder="مثلاً 1350" /></label>
        </div>
      </div>
    </fieldset>
  );
}
