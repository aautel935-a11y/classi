"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { savePhotoAction } from "@/app/actions";
import { Avatar } from "./Avatar";
import { friendlyError } from "@/lib/errors";

type Kind = "teacher" | "institute" | "profile";

/** Shrinks the picture in the browser (max 512px, JPEG) before uploading it. */
async function shrink(file: File): Promise<Blob> {
  const bitmap = await createImageBitmap(file).catch(async () => {
    // Some phones (HEIC photos) need the <img> decoder instead.
    const img = new Image();
    img.src = URL.createObjectURL(file);
    await img.decode();
    return img as unknown as ImageBitmap;
  });
  const scale = Math.min(1, 512 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  return new Promise((res, rej) => canvas.toBlob((b) => (b ? res(b) : rej(new Error("x"))), "image/jpeg", 0.85));
}

export function PhotoUpload({ kind, name, current }: { kind: Kind; name: string; current: string | null }) {
  const router = useRouter();
  const input = useRef<HTMLInputElement>(null);
  const [preview, setPreview] = useState<string | null>(current);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onPick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setError(null);
    if (!file.type.startsWith("image/") && !/\.(heic|heif)$/i.test(file.name)) return setError("اختر صورة (JPG أو PNG).");
    setBusy(true);
    try {
      const blob = await shrink(file);
      const supabase = createClient();
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) throw new Error("سجّل الدخول أولاً.");
      const path = `${user.id}/${kind}.jpg`;
      const { error: upErr } = await supabase.storage.from("avatars").upload(path, blob, { upsert: true, contentType: "image/jpeg" });
      if (upErr) throw new Error(`تعذّر رفع الصورة: ${upErr.message}`);
      const url = `${supabase.storage.from("avatars").getPublicUrl(path).data.publicUrl}?v=${Date.now()}`;
      const r = await savePhotoAction(kind, url);
      if (r.error) throw new Error(r.error);
      setPreview(url);
      router.refresh();
    } catch (err) {
      setError(err instanceof Error && err.message ? friendlyError({ message: err.message }) : "تعذّر رفع الصورة، حاول مرة أخرى.");
    } finally {
      setBusy(false);
      if (input.current) input.current.value = "";
    }
  }

  return (
    <div className="photo-up">
      <Avatar name={name} url={preview} size="lg" inst={kind === "institute"} />
      <div className="stack" style={{ gap: 4 }}>
        <button type="button" className="btn sm ghost" onClick={() => input.current?.click()} disabled={busy}>
          {busy ? "جارٍ الرفع…" : preview ? "تغيير الصورة" : kind === "institute" ? "رفع شعار المعهد" : "رفع صورة شخصية"}
        </button>
        <span className="small muted">صورة واضحة للوجه {kind === "institute" ? "أو شعار المعهد" : ""} تزيد ثقة الأهل.</span>
        {error && <span className="small" style={{ color: "var(--bad)" }}>{error}</span>}
      </div>
      <input ref={input} type="file" accept="image/jpeg,image/png,image/webp" hidden onChange={onPick} />
    </div>
  );
}
