// Photos in the public "avatars" bucket: every upload gets its own file name, so a new teacher/institute photo can
// wait for admin review while the approved one keeps showing (and stays if the new one is rejected).
// Files live in the owner's folder (<user id>/...), which the storage policies limit to that user.
// Pure functions only (no network), shared by the upload component and the server actions, and unit-tested.

export type PhotoKind = "teacher" | "institute" | "profile";
export const PHOTO_KINDS: readonly PhotoKind[] = ["teacher", "institute", "profile"];

/** How long an unreferenced file is kept before cleanup may delete it: covers an upload whose link is still being
 * saved (upload and save are two steps), so cleanup in another tab can never delete a photo that is about to be used. */
export const PHOTO_MIN_AGE_MS = 2 * 60 * 1000;

const PUBLIC_PREFIX = "/storage/v1/object/public/avatars/";

/** A new, unique file name for one upload: "<kind>-<time>-<random>.jpg". */
export function newPhotoName(kind: PhotoKind, now = Date.now(), random = Math.random()): string {
  const r = Math.floor(random * 36 ** 8).toString(36).padStart(8, "0");
  return `${kind}-${now.toString(36)}-${r}.jpg`;
}

/** True for a file of this kind: the old fixed name "<kind>.jpg" (photos saved before unique names) or a unique name. */
export function isKindFile(name: string, kind: PhotoKind): boolean {
  return name === `${kind}.jpg` || new RegExp(`^${kind}-[0-9a-z]{1,12}-[0-9a-z]{8}\\.jpg$`).test(name);
}

/** "<owner>/<file>" inside the avatars bucket for a public photo link, or null for anything else. */
export function photoPath(url: string | null | undefined): string | null {
  if (!url) return null;
  try {
    const u = new URL(url);
    if (!u.pathname.startsWith(PUBLIC_PREFIX)) return null;
    const path = decodeURIComponent(u.pathname.slice(PUBLIC_PREFIX.length));
    // exactly "<folder>/<file>": no deeper paths, no "..", no empty parts
    const parts = path.split("/");
    if (parts.length !== 2 || parts.some((p) => !p || p === "." || p === "..")) return null;
    return path;
  } catch {
    return null;
  }
}

/** A link the owner may save as their photo of this kind: https, on this project's storage, in their own folder,
 * with a file name of that kind. */
export function validPhotoUrl(url: string, { host, owner, kind }: { host: string; owner: string; kind: PhotoKind }): boolean {
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" || u.hostname !== host || u.username || u.password) return false;
    const path = photoPath(url);
    if (!path) return false;
    const [folder, file] = path.split("/");
    return folder === owner && isKindFile(file, kind);
  } catch {
    return false;
  }
}

export type StoredFile = { name: string; created_at?: string | null };

/** Which of the owner's files of this kind cleanup may delete: never a file that is still in use (`keep`: the approved
 * photo and the one waiting for review), never another kind's file, never one younger than `minAgeMs`, and only
 * files inside the owner's folder. Returns full paths ("<owner>/<file>"). */
export function photosToDelete({ owner, kind, files, keep, now = Date.now(), minAgeMs = PHOTO_MIN_AGE_MS }: {
  owner: string; kind: PhotoKind; files: StoredFile[]; keep: (string | null | undefined)[]; now?: number; minAgeMs?: number;
}): string[] {
  const keepSet = new Set(keep.filter((k): k is string => !!k));
  return files
    .filter((f) => isKindFile(f.name, kind))
    .filter((f) => {
      const at = f.created_at ? Date.parse(f.created_at) : NaN;
      return Number.isFinite(at) && now - at >= minAgeMs;         // unknown age: keep (fail safe)
    })
    .map((f) => `${owner}/${f.name}`)
    .filter((p) => !keepSet.has(p));
}

/** Files that were in use before a change and no longer are (the replaced or removed photo): safe to delete at once.
 * Only the owner's own files of this kind. */
export function noLongerUsed({ owner, kind, before, after }: {
  owner: string; kind: PhotoKind; before: (string | null | undefined)[]; after: (string | null | undefined)[];
}): string[] {
  const now = new Set(after.filter(Boolean));
  return [...new Set(before.filter((p): p is string => !!p))]
    .filter((p) => !now.has(p))
    .filter((p) => { const [folder, file] = p.split("/"); return folder === owner && !!file && isKindFile(file, kind); });
}

// ---------- private photos (migrations 20261105000000 / 20261105010000) ----------
// A teacher's or institute's new photo is uploaded to the private bucket and waits there (<owner>/pending/…) until
// the admin publishes it to the public bucket; profile photos (students, parents) live only in the private bucket
// (<owner>/profile-…) and are shown through short signed links. Users never write to the public bucket.

export const PUBLIC_BUCKET = "avatars";
export const PRIVATE_BUCKET = "photos-private";

/** How long a signed link to a private photo works, by who looks at it. */
export const SIGNED_SECONDS = { profile: 60 * 60, ownerWaiting: 10 * 60, admin: 5 * 60 } as const;

/** Where a new private upload goes: a waiting teacher/institute photo under "pending/", a profile photo in the folder. */
export function newPrivatePath(owner: string, kind: PhotoKind, now = Date.now(), random = Math.random()): string {
  const file = newPhotoName(kind, now, random);
  return kind === "profile" ? `${owner}/${file}` : `${owner}/pending/${file}`;
}

const UNIQUE = (kind: PhotoKind) => new RegExp(`^${kind}-[0-9a-z]{1,12}-[0-9a-z]{8}\\.jpg$`);

/** A private path the owner may submit for this kind (the same rule as submit_photo in the database). */
export function validPrivatePath(path: string | null | undefined, { owner, kind }: { owner: string; kind: PhotoKind }): boolean {
  if (!path || !owner) return false;
  const parts = path.split("/");
  if (kind === "profile") return parts.length === 2 && parts[0] === owner && UNIQUE(kind).test(parts[1]);
  return parts.length === 3 && parts[0] === owner && parts[1] === "pending" && UNIQUE(kind).test(parts[2]);
}

/** The owner of a valid private path (its folder), or null. */
export function privateOwner(path: string | null | undefined, kind: PhotoKind): string | null {
  const owner = (path ?? "").split("/")[0];
  return owner && validPrivatePath(path, { owner, kind }) ? owner : null;
}

/** Where an approved waiting photo is published: a new unique name in the owner's public folder. */
export function publishedPath(waiting: string, kind: "teacher" | "institute", now = Date.now(), random = Math.random()): string | null {
  const owner = privateOwner(waiting, kind);
  return owner ? `${owner}/${newPhotoName(kind, now, random)}` : null;
}

/** Which of the owner's private files of this kind cleanup may delete: same rules as photosToDelete (never in use, never
 * younger than minAgeMs, only this kind), for the files listed in the private folder of that kind. */
export function privateToDelete({ owner, kind, files, keep, now = Date.now(), minAgeMs = PHOTO_MIN_AGE_MS }: {
  owner: string; kind: PhotoKind; files: StoredFile[]; keep: (string | null | undefined)[]; now?: number; minAgeMs?: number;
}): string[] {
  const folder = kind === "profile" ? owner : `${owner}/pending`;
  const keepSet = new Set(keep.filter((k): k is string => !!k));
  return files
    .filter((f) => UNIQUE(kind).test(f.name))
    .filter((f) => {
      const at = f.created_at ? Date.parse(f.created_at) : NaN;
      return Number.isFinite(at) && now - at >= minAgeMs;         // unknown age: keep (fail safe)
    })
    .map((f) => `${folder}/${f.name}`)
    .filter((p) => !keepSet.has(p) && validPrivatePath(p, { owner, kind }));
}
