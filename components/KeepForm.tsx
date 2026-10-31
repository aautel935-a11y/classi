"use client";

import { useEffect } from "react";

// Forms post to server actions that redirect back with "?error=…" when something is wrong, which reloads the page
// with empty fields (BUG-07). <KeepForm formId> remembers what was typed (this tab only, sessionStorage) and puts
// it back when the page returns with an error; a successful save (no "error" in the address) forgets it.
// File and password fields are never stored; hidden fields only when marked data-keep="1" (state a client
// component restores itself through readKept, e.g. the offer type). Restoring waits a moment so that such
// state has re-rendered its fields first.

const KEY = (id: string) => `classi-form:${id}`;
type Saved = Record<string, string[]>;

function hasError() {
  try { return new URLSearchParams(window.location.search).has("error"); } catch { return false; }
}

/** What was typed in this form before the last failed submit (for client components that keep state). */
export function readKept(formId: string): Saved | null {
  if (typeof window === "undefined" || !hasError()) return null;
  try { const s = sessionStorage.getItem(KEY(formId)); return s ? (JSON.parse(s) as Saved) : null; } catch { return null; }
}

function serialize(form: HTMLFormElement): Saved {
  const out: Saved = {};
  for (const el of Array.from(form.elements) as HTMLInputElement[]) {
    if (!el.name || el.disabled) continue;
    if (el.type === "hidden" ? el.dataset.keep !== "1" : ["file", "password", "submit", "button"].includes(el.type)) continue;
    if ((el.type === "checkbox" || el.type === "radio")) { if (el.checked) (out[el.name] ??= []).push(el.value || "on"); else out[el.name] ??= []; continue; }
    (out[el.name] ??= []).push(el.value);
  }
  return out;
}

function setNative(el: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement, value: string) {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value")?.set?.call(el, value);   // so React's onChange sees it too
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
}

function restore(form: HTMLFormElement, saved: Saved) {
  const seen: Record<string, number> = {};
  for (const el of Array.from(form.elements) as HTMLInputElement[]) {
    const vals = el.name ? saved[el.name] : undefined;
    if (!vals || ["hidden", "file", "password", "submit", "button"].includes(el.type)) continue;
    if (el.type === "checkbox" || el.type === "radio") {
      const want = vals.includes(el.value || "on");
      if (el.checked !== want) el.click();
      continue;
    }
    const i = (seen[el.name] = (seen[el.name] ?? -1) + 1);
    if (vals[i] !== undefined) setNative(el, vals[i]);
  }
}

export function KeepForm({ formId }: { formId: string }) {
  useEffect(() => {
    const form = document.getElementById(formId) as HTMLFormElement | null;
    if (!form) return;
    try {
      if (hasError()) {
        const s = sessionStorage.getItem(KEY(formId));
        if (s) setTimeout(() => { const f = document.getElementById(formId) as HTMLFormElement | null; if (f) restore(f, JSON.parse(s) as Saved); }, 60);
      }
      else sessionStorage.removeItem(KEY(formId));
    } catch { /* private mode or storage blocked: the form simply starts empty */ }
    const onSubmit = () => { try { sessionStorage.setItem(KEY(formId), JSON.stringify(serialize(form))); } catch { /* ignore */ } };
    form.addEventListener("submit", onSubmit);
    return () => form.removeEventListener("submit", onSubmit);
  }, [formId]);
  return null;
}
