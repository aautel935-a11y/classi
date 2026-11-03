"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { removePhotoAction, submitPhotoAction, tidyPhotosAction } from "@/app/actions";
import { Avatar } from "./Avatar";
import { friendlyError } from "@/lib/errors";
import { PRIVATE_BUCKET, newPrivatePath, type PhotoKind as Kind } from "@/lib/photos";

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

/** Photo box. `current`: the photo shown now (the approved public teacher/institute photo, or a short signed link to the
 * private profile photo). `waiting`: a short signed link to the teacher's/institute's new photo waiting for the admin
 * (private: only the owner and the admin can open it). Uploads go to the private bucket only (lib/photos.ts). */
export function PhotoUpload({ kind, name, current, waiting = null }: { kind: Kind; name: string; current: string | null; waiting?: string | null }) {
  const router = useRouter();
  const input = useRef<HTMLInputElement>(null);
  const [preview, setPreview] = useState<string | null>(current);
  const [waitingPreview, setWaitingPreview] = useState<string | null>(waiting);
  // the page passes fresh signed links after router.refresh(): show them instead of the local preview
  useEffect(() => { setPreview(current); }, [current]);
  useEffect(() => { setWaitingPreview(waiting); }, [waiting]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const reviewed = kind !== "profile";                     // teacher/institute photos wait for admin review

  // Quietly clear this account's unused photo files (a rejected photo, or the previous one after an approval).
  useEffect(() => { tidyPhotosAction(kind).catch(() => undefined); }, [kind]);

  async function onPick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setError(null);
    setNote(null);
    if (!file.type.startsWith("image/") && !/\.(heic|heif)$/i.test(file.name)) return setError("اختر صورة (JPG أو PNG).");
    setBusy(true);
    try {
      const blob = await shrink(file);
      const supabase = createClient();
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) throw new Error("سجّل الدخول أولاً.");
      // A new private file every time (never overwrite, never public): a teacher's/institute's photo waits privately
      // for the admin, who publishes it; the approved photo stays untouched meanwhile. A profile photo stays private.
      const path = newPrivatePath(user.id, kind);
      const { error: upErr } = await supabase.storage.from(PRIVATE_BUCKET).upload(path, blob, { upsert: false, contentType: "image/jpeg" });
      if (upErr) throw new Error(`تعذّر رفع الصورة: ${upErr.message}`);
      const r = await submitPhotoAction(kind, path);
      if (r.error) {
        // not saved: this new file is used by nothing, so it is removed again
        await supabase.storage.from(PRIVATE_BUCKET).remove([path]).catch(() => undefined);
        throw new Error(r.error);
      }
      const local = URL.createObjectURL(blob);                 // shown until the page sends its signed link
      if (reviewed) setWaitingPreview(local); else setPreview(local);
      setNote(reviewed ? "وصلت الصورة الجديدة للإدارة للمراجعة. لا تظهر لأحد غيرك قبل الموافقة، وتبقى صورتك الحالية ظاهرة للأهل." : null);
      router.refresh();
    } catch (err) {
      setError(err instanceof Error && err.message ? friendlyError({ message: err.message }) : "تعذّر رفع الصورة، حاول مرة أخرى.");
    } finally {
      setBusy(false);
      if (input.current) input.current.value = "";
    }
  }

  async function onRemove() {
    setError(null);
    setNote(null);
    setBusy(true);
    try {
      const r = await removePhotoAction(kind);
      if (r.error) throw new Error(r.error);
      setPreview(null);
      setNote(reviewed ? "طلب إزالة الصورة وصل للإدارة للمراجعة. تبقى الصورة الحالية ظاهرة حتى الموافقة." : null);
      router.refresh();
    } catch (err) {
      setError(err instanceof Error && err.message ? friendlyError({ message: err.message }) : "تعذّرت إزالة الصورة، حاول مرة أخرى.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="photo-up" data-can-remove="1" data-unique-files="1" data-private="1">
      <Avatar name={name} url={preview} size="lg" inst={kind === "institute"} />
      {reviewed && waitingPreview && (
        <figure className="stack" style={{ gap: 2, margin: 0, alignItems: "center" }}>
          <img className="waiting-photo" src={waitingPreview} alt="الصورة الجديدة بانتظار الموافقة" width={56} height={56}
               style={{ width: 56, height: 56, borderRadius: 12, objectFit: "cover", opacity: 0.85 }} />
          <figcaption className="small muted">بانتظار الموافقة</figcaption>
        </figure>
      )}
      <div className="stack" style={{ gap: 4 }}>
        <button type="button" className="btn sm ghost" onClick={() => input.current?.click()} disabled={busy}>
          {busy ? "جارٍ الرفع…" : preview ? "تغيير الصورة" : kind === "institute" ? "رفع شعار المعهد" : "رفع صورة شخصية"}
        </button>
        {preview && (
          <button type="button" className="link small" onClick={onRemove} disabled={busy} style={{ alignSelf: "flex-start" }}>
            إزالة الصورة
          </button>
        )}
        <span className="small muted">صورة واضحة للوجه {kind === "institute" ? "أو شعار المعهد" : ""} تزيد ثقة الأهل.</span>
        {note && <span className="small okmsg" role="status">{note}</span>}
        {error && <span className="small" role="alert" style={{ color: "var(--bad)" }}>{error}</span>}
      </div>
      <input ref={input} type="file" accept="image/jpeg,image/png,image/webp" hidden onChange={onPick} />
    </div>
  );
}
