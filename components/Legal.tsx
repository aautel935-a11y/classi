import Link from "next/link";
import { Icon } from "@/components/Icon";

export const LEGAL_UPDATED = "25 أكتوبر 2026";

/** Shared frame for the terms and privacy pages. */
export function Legal({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="wrap">
      <article className="section legal">
        <Link className="back" href="/"><Icon name="back" />الرئيسية</Link>
        <h1>{title}</h1>
        <p className="small muted">آخر تحديث: {LEGAL_UPDATED}</p>
        {children}
        <p className="small muted">
          <Link className="link" href="/terms">شروط الاستخدام</Link> · <Link className="link" href="/privacy">سياسة الخصوصية</Link> · <a className="link" href="mailto:classi@torix.click" dir="ltr">classi@torix.click</a>
        </p>
      </article>
    </div>
  );
}
