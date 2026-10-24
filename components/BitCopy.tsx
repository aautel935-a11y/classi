"use client";

import { useState } from "react";

const local = (p: string) => p.replace(/^\+972/, "0");
const pretty = (p: string) => local(p).replace(/^(\d{3})(\d{3})(\d{4})$/, "$1-$2-$3");

/** The Bit number with one tap to copy it and open the Bit app (Android opens it directly; on iPhone open Bit yourself). */
export function BitCopy({ phone }: { phone: string }) {
  const [copied, setCopied] = useState(false);
  async function go() {
    try { await navigator.clipboard.writeText(local(phone)); setCopied(true); } catch {}
    if (/android/i.test(navigator.userAgent)) {
      window.location.href = "intent://#Intent;package=com.bnhp.payments.paymentsapp;S.browser_fallback_url=https%3A%2F%2Fplay.google.com%2Fstore%2Fapps%2Fdetails%3Fid%3Dcom.bnhp.payments.paymentsapp;end";
    }
  }
  return (
    <div className="row" style={{ gap: 10, flexWrap: "wrap" }}>
      <b className="num bitnum" dir="ltr">{pretty(phone)}</b>
      <button type="button" className="btn sm" onClick={go}>{copied ? "نُسخ الرقم ✓ افتح Bit" : "انسخ الرقم وافتح Bit"}</button>
    </div>
  );
}
