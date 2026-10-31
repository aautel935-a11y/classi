"use client";

import { useEffect } from "react";
import { useSearchParams } from "next/navigation";

// Forms post to server actions that redirect back with "?error=…" when something is wrong (BUG-07). That is a
// client-side navigation: the page stays mounted and React resets the form, so what was typed is lost.
// <KeepForm formId> remembers the typed values (this tab only, sessionStorage) when the form is submitted and puts
// them back when the address gains an "error"; when it changes without an error (a successful save) the copy is
// dropped. Rules that keep it from restoring the wrong thing:
//  - formId must include the record (e.g. "kf-updateOffering-<offer id>"), so one course never fills another;
//  - a copy older than 30 minutes is ignored; the login page clears every copy (shared devices);
//  - file and password fields are never stored; hidden fields only when marked data-keep="1" (state a client
//    component restores itself through readKept, e.g. the offer type).

const PREFIX = "classi-form:";
const MAX_AGE = 30 * 60 * 1000;
type Saved = Record<string, string[]>;
type Stored = { at: number; values: Saved };

function load(formId: string): Saved | null {
  try {
    const s = sessionStorage.getItem(PREFIX + formId);
    if (!s) return null;
    const v = JSON.parse(s) as Stored;
    if (!v?.at || Date.now() - v.at > MAX_AGE) { sessionStorage.removeItem(PREFIX + formId); return null; }
    return v.values;
  } catch { return null; }
}

/** What was typed in this form before the last failed submit (for client components that keep state). */
export function readKept(formId: string): Saved | null {
  if (typeof window === "undefined") return null;
  try { if (!new URLSearchParams(window.location.search).has("error")) return null; } catch { return null; }
  return load(formId);
}

/** Forget every remembered form (called on the login screen, so the next person never sees someone's input). */
export function clearKeptForms() {
  try {
    for (let i = sessionStorage.length - 1; i >= 0; i--) {
      const k = sessionStorage.key(i);
      if (k?.startsWith(PREFIX)) sessionStorage.removeItem(k);
    }
  } catch { /* storage blocked */ }
}

function skip(el: HTMLInputElement) {
  return !el.name || el.disabled || (el.type === "hidden" ? el.dataset.keep !== "1" : ["file", "password", "submit", "button"].includes(el.type));
}

function serialize(form: HTMLFormElement): Saved {
  const out: Saved = {};
  for (const el of Array.from(form.elements) as HTMLInputElement[]) {
    if (skip(el)) continue;
    if (el.type === "checkbox" || el.type === "radio") { out[el.name] ??= []; if (el.checked) out[el.name].push(el.value || "on"); continue; }
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
    if (skip(el) || el.type === "hidden") continue;
    const vals = saved[el.name];
    if (!vals) continue;
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
  const error = useSearchParams().get("error");

  // Remember the values at submit time.
  useEffect(() => {
    const form = document.getElementById(formId) as HTMLFormElement | null;
    if (!form) return;
    const onSubmit = () => {
      try { sessionStorage.setItem(PREFIX + formId, JSON.stringify({ at: Date.now(), values: serialize(form) } satisfies Stored)); } catch { /* ignore */ }
    };
    form.addEventListener("submit", onSubmit);
    return () => form.removeEventListener("submit", onSubmit);
  }, [formId]);

  // Every time the address changes: an error puts the values back (after React has reset the form and any
  // client state has re-rendered its fields); no error means the save worked, so the copy is dropped.
  useEffect(() => {
    if (!error) { try { sessionStorage.removeItem(PREFIX + formId); } catch { /* ignore */ } return; }
    const saved = load(formId);
    if (!saved) return;
    const t = setTimeout(() => {
      const form = document.getElementById(formId) as HTMLFormElement | null;
      if (form) restore(form, saved);
    }, 80);
    return () => clearTimeout(t);
  }, [formId, error]);
  return null;
}
