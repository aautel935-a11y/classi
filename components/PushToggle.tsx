"use client";

import { useEffect, useState, useTransition } from "react";
import { removePushSubscriptionAction, savePushSubscriptionAction } from "@/app/actions";
import { VAPID_PUBLIC } from "@/lib/push";
import { Icon } from "@/components/Icon";

type State = "loading" | "unsupported" | "ios-install" | "denied" | "off" | "on";

function keyBytes(b64: string) {
  const pad = "=".repeat((4 - (b64.length % 4)) % 4);
  const raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

/** "Turn on phone notifications": reminders and answers arrive even when the app is closed. */
export function PushToggle({ compact = false }: { compact?: boolean }) {
  const [state, setState] = useState<State>("loading");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  useEffect(() => {
    (async () => {
      const w = window as any;
      const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
      const standalone = w.matchMedia?.("(display-mode: standalone)").matches || w.navigator.standalone;
      if (!("serviceWorker" in navigator) || !("PushManager" in w) || !("Notification" in w)) {
        return setState(ios && !standalone ? "ios-install" : "unsupported");
      }
      if (Notification.permission === "denied") return setState("denied");
      const reg = await navigator.serviceWorker.register("/sw.js");
      const sub = await reg.pushManager.getSubscription();
      if (sub) {
        // Keep the server copy fresh (e.g. after signing in on a shared phone).
        const j = sub.toJSON() as any;
        savePushSubscriptionAction({ endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth });
      }
      setState(sub ? "on" : "off");
    })().catch(() => setState("unsupported"));
  }, []);

  function enable() {
    setError(null);
    start(async () => {
      try {
        const perm = await Notification.requestPermission();
        if (perm !== "granted") return setState(perm === "denied" ? "denied" : "off");
        const reg = await navigator.serviceWorker.register("/sw.js");
        await navigator.serviceWorker.ready;
        const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(VAPID_PUBLIC) });
        const j = sub.toJSON() as any;
        const r = await savePushSubscriptionAction({ endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth });
        if (r.error) return setError(r.error);
        setState("on");
      } catch {
        setError("تعذّر تفعيل التنبيهات على هذا الجهاز. جرّب من متصفح Chrome أو من التطبيق المثبّت.");
      }
    });
  }

  function disable() {
    start(async () => {
      const reg = await navigator.serviceWorker.getRegistration();
      const sub = await reg?.pushManager.getSubscription();
      if (sub) {
        await removePushSubscriptionAction(sub.endpoint);
        await sub.unsubscribe();
      }
      setState("off");
    });
  }

  if (state === "loading" || (compact && (state === "on" || state === "unsupported"))) return null;

  return (
    <div className="card push-card">
      <div className="row" style={{ alignItems: "flex-start", gap: 10 }}>
        <span className="ico"><Icon name="bell" /></span>
        <div className="stack" style={{ gap: 4, flex: 1, minWidth: 0 }}>
          <b>{state === "on" ? "تنبيهات الهاتف مفعّلة" : "تنبيهات على الهاتف"}</b>
          <span className="small muted">
            {state === "on" && "يصلك تذكير قبل كل حصة بيوم وقبلها بساعة، وكل رد أو تغيير موعد، حتى والتطبيق مغلق."}
            {state === "off" && "تذكير قبل الحصة بيوم وبساعة، وإشعار فوري عند الرد على حجزك أو تغيير الموعد."}
            {state === "denied" && "التنبيهات محظورة لهذا الموقع. افتح إعدادات المتصفح ← إعدادات الموقع ← الإشعارات، واسمح لـ Classi."}
            {state === "ios-install" && "في iPhone: اضغط زر المشاركة ثم «إضافة إلى الشاشة الرئيسية»، وافتح Classi من الأيقونة لتفعيل التنبيهات."}
            {state === "unsupported" && "هذا المتصفح لا يدعم التنبيهات. التذكيرات تصلك هنا في صفحة الإشعارات."}
          </span>
          {error && <span className="err small">{error}</span>}
        </div>
      </div>
      {state === "off" && <button className="btn" disabled={pending} onClick={enable}>{pending ? "جارٍ التفعيل…" : "فعّل التنبيهات"}</button>}
      {state === "on" && <button className="link small" disabled={pending} onClick={disable}>إيقاف التنبيهات على هذا الجهاز</button>}
    </div>
  );
}
