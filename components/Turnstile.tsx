"use client";

import { useEffect, useRef } from "react";

// Cloudflare Turnstile (free CAPTCHA) for the sign-in code request (SEC-08). Active only when
// NEXT_PUBLIC_TURNSTILE_SITE_KEY is set AND captcha is enabled in Supabase Auth with the matching secret key;
// otherwise nothing is rendered and sign-in works as before.

declare global {
  interface Window { turnstile?: { render: (el: HTMLElement, o: Record<string, unknown>) => string; reset: (id?: string) => void; remove: (id: string) => void } }
}

export const TURNSTILE_SITE_KEY = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY || "";

export function Turnstile({ onToken, resetKey }: { onToken: (t: string | null) => void; resetKey: number }) {
  const box = useRef<HTMLDivElement>(null);
  const widget = useRef<string | null>(null);
  useEffect(() => {
    if (!TURNSTILE_SITE_KEY || !box.current) return;
    let cancelled = false;
    const mount = () => {
      if (cancelled || !box.current || !window.turnstile) return;
      if (widget.current) window.turnstile.remove(widget.current);
      widget.current = window.turnstile.render(box.current, {
        sitekey: TURNSTILE_SITE_KEY, language: "ar", action: "otp",
        callback: (t: string) => onToken(t), "expired-callback": () => onToken(null), "error-callback": () => onToken(null),
      });
    };
    if (window.turnstile) mount();
    else if (!document.getElementById("cf-turnstile")) {
      const s = document.createElement("script");
      s.id = "cf-turnstile"; s.async = true; s.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
      s.onload = mount; document.head.appendChild(s);
    } else document.getElementById("cf-turnstile")!.addEventListener("load", mount);
    return () => { cancelled = true; };
  }, [onToken, resetKey]);
  if (!TURNSTILE_SITE_KEY) return null;
  return <div ref={box} style={{ minHeight: 65 }} />;
}
