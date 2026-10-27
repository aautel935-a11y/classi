"use client";

import { useState } from "react";
import { usePathname } from "next/navigation";
import { waLink } from "@/lib/contact";

/** Small floating "need help?" button that opens a WhatsApp chat with Classi support. */
export function SupportButton({ phone }: { phone: string | null }) {
  const path = usePathname();
  const [open, setOpen] = useState(false);
  if (!phone || path.startsWith("/admin") || path.startsWith("/login")) return null;
  const href = waLink(phone, `مرحباً إدارة Classi، أحتاج مساعدة${path && path !== "/" ? ` (في صفحة ${path})` : ""}:`);
  return (
    <div className={`support ${open ? "open" : ""}`}>
      {open && (
        <div className="support-card" role="dialog" aria-label="مساعدة">
          <b>بحاجة لمساعدة؟</b>
          <span className="small muted">تواصل مع إدارة Classi على واتساب، نرد عليك ونساعدك خطوة بخطوة.</span>
          <a className="btn sm wa" href={href!} target="_blank" rel="noopener noreferrer">افتح واتساب</a>
        </div>
      )}
      <button type="button" className="support-fab" aria-label={open ? "إغلاق المساعدة" : "بحاجة لمساعدة؟ تواصل مع إدارة Classi"} onClick={() => setOpen(!open)}>
        {open ? "×" : "؟"}
      </button>
    </div>
  );
}
