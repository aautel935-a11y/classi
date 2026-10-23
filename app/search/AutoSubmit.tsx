"use client";
import { useEffect } from "react";

/** Re-runs the search when a filter changes, and after typing stops. */
export function AutoSubmit({ formId }: { formId: string }) {
  useEffect(() => {
    const form = document.getElementById(formId) as HTMLFormElement | null;
    if (!form) return;
    let t: ReturnType<typeof setTimeout>;
    const onChange = () => form.requestSubmit();
    const onInput = (e: Event) => {
      if ((e.target as HTMLElement).tagName !== "INPUT") return;
      clearTimeout(t);
      t = setTimeout(() => form.requestSubmit(), 600);
    };
    form.addEventListener("change", onChange);
    form.addEventListener("input", onInput);
    return () => {
      form.removeEventListener("change", onChange);
      form.removeEventListener("input", onInput);
      clearTimeout(t);
    };
  }, [formId]);
  return null;
}
