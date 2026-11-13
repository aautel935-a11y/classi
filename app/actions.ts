"use server";

import { revalidatePath, revalidateTag } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { fromLocal } from "@/lib/format";
import { datesOn, nextDays } from "@/lib/dates";
import { cleanMobile } from "@/lib/contact";
import type { OfferingType, Place, Role } from "@/lib/types";
import { safePath } from "@/lib/safe";
import { friendlyError } from "@/lib/errors";
import {
  PHOTO_KINDS, PRIVATE_BUCKET, PUBLIC_BUCKET, noLongerUsed, photoPath, photosToDelete, privateOwner, privateToDelete, publishedPath,
  validPrivatePath, type PhotoKind,
} from "@/lib/photos";

type Result = { error?: string; ok?: boolean; count?: number; created?: number; skipped?: string[] };

async function client() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  return { supabase, user };
}
const str = (f: FormData, k: string) => String(f.get(k) ?? "").trim();
const num = (f: FormData, k: string) => Number(f.get(k) ?? 0);

// ---------- booking ----------
export async function bookAction(input: {
  offeringId: string;
  childId?: string | null;
  startsAt?: string | null;
  sessionId?: string | null;
  pay: string;
  weekly?: boolean;
  mode?: Place | null;
  trial?: boolean;
}): Promise<Result> {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً لإتمام الحجز." };
  if (input.trial && !input.weekly) {
    const { error } = await supabase.rpc("create_trial_booking", {
      p_offering: input.offeringId, p_child: input.childId || null, p_starts_at: input.startsAt || null, p_pay: input.pay, p_mode: input.mode || null,
    });
    if (error) return { error: friendlyError(error) };
    revalidatePath("/schedule");
    return { ok: true };
  }
  if (input.weekly) {
    const { data, error } = await supabase.rpc("create_weekly_booking", {
      p_offering: input.offeringId,
      p_child: input.childId || null,
      p_starts_at: input.startsAt || null,
      p_session: input.sessionId || null,
      p_pay: input.pay,
      p_mode: input.mode || null,
    });
    if (error) return { error: friendlyError(error) };
    revalidatePath("/schedule");
    const res = data as { created: number; skipped: string[] };
    return { ok: true, created: res.created, skipped: res.skipped };
  }
  const { error } = await supabase.rpc("create_booking", {
    p_offering: input.offeringId,
    p_child: input.childId || null,
    p_starts_at: input.startsAt || null,
    p_session: input.sessionId || null,
    p_pay: input.pay,
    p_weekly: !!input.weekly,
    p_mode: input.mode || null,
  });
  if (error) return { error: friendlyError(error) };
  revalidatePath("/schedule");
  return { ok: true };
}

export async function cancelBookingAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const { error } = await supabase.rpc("cancel_booking", { p_booking: str(form, "id") });
  revalidatePath("/schedule");
  if (error) redirect(`/schedule?error=${encodeURIComponent(friendlyError(error))}`);
}

export async function respondAction(form: FormData) {
  const { supabase } = await client();
  const { error } = await supabase.rpc("respond_booking", { p_booking: str(form, "id"), p_accept: str(form, "accept") === "1" });
  revalidatePath("/teach");
  if (error) redirect(`/teach?error=${encodeURIComponent(friendlyError(error))}`);
}

// ---------- rescheduling ----------
export async function rescheduleAction(input: {
  sessionId: string;
  day: string;
  time: string;
  roomId?: string | null;
  scope: "one" | "following";
  reason?: string;
  path: string;
}): Promise<Result> {
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(input.day) || !/^\d{2}:\d{2}$/.test(input.time)) return { error: "اختر تاريخاً وساعة." };
  const { data, error } = await supabase.rpc("reschedule_session", {
    p_session: input.sessionId,
    p_starts_at: fromLocal(input.day, input.time).toISOString(),
    p_room: input.roomId || null,
    p_scope: input.scope,
    p_reason: input.reason || null,
  });
  if (error) return { error: friendlyError(error) };
  revalidatePath(safePath(input.path, "/"));
  return { ok: true, count: data as number };
}

// ---------- notifications ----------
export async function markAllReadAction() {
  const { supabase, user } = await client();
  if (!user) return;
  await supabase.from("notifications").update({ read_at: new Date().toISOString() }).is("read_at", null);
  revalidatePath("/", "layout");
}

// ---------- account ----------
export async function signOutAction() {
  const { supabase } = await client();
  await supabase.auth.signOut();
  redirect("/");
}

// D-08 / TM-21: a lost or shared device. Revokes every session of this account (all refresh tokens), here and elsewhere;
// other devices are signed out when their short access token expires (at most an hour) or at once on their next refresh.
export async function signOutEverywhereAction() {
  const { supabase } = await client();
  await supabase.auth.signOut({ scope: "global" });
  redirect("/login?signed_out=all");
}

export async function switchRoleAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const role = str(form, "role") as Role;
  if (!["guardian", "student", "teacher", "institute"].includes(role)) return;
  const { data: p } = await supabase.from("profiles").select("roles").eq("id", user.id).single();
  const roles = Array.from(new Set([...(p?.roles ?? []), role]));
  await supabase.from("profiles").update({ roles, active_role: role }).eq("id", user.id);
  revalidatePath("/", "layout");
  redirect(role === "teacher" ? "/teach" : role === "institute" ? "/manage" : "/");
}

export async function updateProfileAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  // The phone is changed only through a verified SMS code (PhoneLink), never typed in here.
  const { error } = await supabase.from("profiles").update({ full_name: str(form, "full_name"), town: str(form, "town") || null, sms_ok: form.get("sms_ok") === "on" }).eq("id", user.id);
  revalidatePath("/account");
  if (error) redirect(`/account?error=${encodeURIComponent(friendlyError(error))}`);
}

export async function addChildAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const name = str(form, "name");
  if (!name) return;
  const { error } = await supabase.from("children").insert({ guardian_id: user.id, name, grade: str(form, "grade") || null });
  revalidatePath("/account");
  if (error) redirect(`/account?error=${encodeURIComponent(friendlyError(error))}#children`);
  // Coming from the booking sheet: go back to the offer (UX-11).
  const back = safePath(str(form, "back"), "");
  if (back) redirect(back);
}

export async function removeChildAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/account");
  // The database refuses while the child has upcoming lessons, a package or a weekly series (BUG-05).
  const { error } = await supabase.from("children").delete().eq("id", str(form, "id"));
  revalidatePath("/account");
  redirect(`/account?${error ? `error=${encodeURIComponent(friendlyError(error))}` : "ok=child_removed"}#children`);
}

// ---------- teacher ----------
export async function teacherSetupAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach");
  const { error } = await supabase.from("teachers").insert({
    user_id: user.id,
    name: str(form, "name"),
    town: str(form, "town"),
    subject_id: num(form, "subject_id") || null,
    bio: str(form, "bio"),
    years: num(form, "years"),
    is_school_teacher: form.get("school") === "on",
  });
  if (error) redirect(`/teach?error=${encodeURIComponent("تعذّر حفظ الملف: " + friendlyError(error))}`);
  revalidatePath("/teach");
  // A different address than the form's: a redirect to the same URL left the setup form on screen after saving.
  redirect("/teach?ok=setup");
}

// Trial lesson and lesson packages from the offer form (both optional).
function offerExtras(form: FormData, type: string): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (type === "private") out.trial_price = form.get("trial_on") === "on" ? Math.max(0, num(form, "trial_price") || 0) : null;
  if (type === "private" || type === "group") {
    const size = Math.round(num(form, "package_size"));
    const price = Math.round(num(form, "package_price"));
    const on = form.get("package_on") === "on";
    out.package_enabled = on && size >= 2 && size <= 50 && price > 0;
    // Size and price are sent only when the package is switched on. The form shows a default size (10) even for an
    // offer without a package; sending it on every save turned unrelated edits (instant confirmation, price, weekly
    // booking) into a content change that waited for admin review (package_size is a reviewed field). Found by S9.
    if (on && size >= 2 && size <= 50) out.package_size = size;
    if (on && price > 0) out.package_price = price;
  }
  return out;
}

export async function newOfferingAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach/new");
  const { data: t } = await supabase.from("teachers").select("id").eq("user_id", user.id).maybeSingle();
  if (!t) redirect("/teach");
  const type = str(form, "type") as OfferingType;
  const placeSel = str(form, "place");
  const places: Place[] = type === "recorded" ? ["online"] : placeSel === "both" ? ["home", "online"] : [(placeSel || "home") as Place];
  const weekday = num(form, "weekday");
  const tm = str(form, "time") || "18:00";
  // Validate before writing anything (an invalid time used to fail after the offer was already saved: BUG-09).
  if (!["private", "group", "recorded"].includes(type)) redirect(`/teach/new?error=${encodeURIComponent("اختر نوع العرض.")}`);
  if (type === "group" && (!Number.isInteger(weekday) || weekday < 0 || weekday > 6 || !/^([01]\d|2[0-3]):[0-5]\d$/.test(tm))) {
    redirect(`/teach/new?error=${encodeURIComponent("اختر يوم اللقاء ووقته بصيغة 00:00.")}`);
  }
  const row: Record<string, unknown> = {
    type,
    teacher_id: t.id,
    title: str(form, "title"),
    subject_id: num(form, "subject_id") || null,
    level_id: num(form, "level_id") || null,
    places,
    price: num(form, "price"),
    minutes: type === "recorded" ? 0 : [30, 45, 60, 90, 120, 150].includes(num(form, "minutes")) ? num(form, "minutes") : type === "group" ? 90 : 60,
    auto_confirm: type === "private" && form.get("auto_confirm") === "on",
    allow_weekly: (type === "private" || type === "group") && form.get("allow_weekly") === "on",
    ...offerExtras(form, type),
  };
  if (type === "group") {
    row.seats = num(form, "seats") || 6;
    row.schedule_note = `كل ${["أحد", "اثنين", "ثلاثاء", "أربعاء", "خميس", "جمعة", "سبت"][weekday]} ${tm}`;
  }
  if (type === "recorded") row.lessons_count = num(form, "lessons") || null;
  const link = str(form, "link");
  if (link && !/^https?:\/\//i.test(link)) redirect(`/teach/new?error=${encodeURIComponent("الرابط يجب أن يبدأ بـ https://")}`);
  const { data: o, error } = await supabase.from("offerings").insert(row).select("id").single();
  if (error || !o) redirect(`/teach/new?error=${encodeURIComponent(error ? friendlyError(error) : "تعذّر النشر")}`);
  // The link and the meetings belong to the offer: if either cannot be saved, the new offer is removed again
  // (it has no bookings yet), so a teacher never ends up with a published group that has no meetings (BUG-09).
  const fail = async (e: { code?: string; message?: string }) => {
    const { data: gone } = await supabase.from("offerings").delete().eq("id", o.id).select("id");
    redirect(`/teach/new?error=${encodeURIComponent(friendlyError(e) + (gone?.length ? "" : " حُفظ العرض ناقصاً، احذفه أو أكمله من لوحتك."))}`);
  };
  if (link) {
    const { error: le } = await supabase.from("offering_links").upsert({ offering_id: o.id, url: link });
    if (le) await fail(le);
  }
  if (type === "group") {
    const days = datesOn(nextDays(1)[0], [weekday], 8);
    const { error: se } = await supabase.from("sessions").insert(
      days.map((d, i) => ({ offering_id: o.id, seq: i + 1, starts_at: fromLocal(d, tm).toISOString(), minutes: Number(row.minutes) || 90 }))
    );
    if (se) await fail(se);
  }
  revalidatePath("/teach");
  redirect("/teach?ok=published");
}

export async function deleteOfferingAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const id = str(form, "id");
  const back = safePath(str(form, "path"), "/teach");
  const { count } = await supabase.from("bookings").select("id", { count: "exact", head: true }).eq("offering_id", id);
  if ((count ?? 0) > 0) redirect(withQ(back, `error=${encodeURIComponent("لا يمكن حذف عرض عليه حجوزات. أخفِه بدلاً من ذلك.")}`));
  // The database refuses to delete an offer that has bookings, packages or reviews (audit SEC-05): 0 rows come back.
  const { data: gone, error } = await supabase.from("offerings").delete().eq("id", id).select("id");
  revalidatePath(back);
  const msg = error ? friendlyError(error) : !gone?.length ? "لا يمكن حذف عرض له حجوزات أو رزم أو تقييمات. أخفِه بدلاً من ذلك." : "";
  redirect(withQ(back, msg ? `error=${encodeURIComponent(msg)}` : "ok=deleted"));
}

export async function toggleOfferingAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = safePath(str(form, "path"), "/teach");
  const active = str(form, "active") === "1";
  const { error } = await supabase.from("offerings").update({ active }).eq("id", str(form, "id"));
  revalidatePath(back);
  redirect(withQ(back, `${error ? `error=${encodeURIComponent(friendlyError(error))}` : active ? "ok=shown" : "ok=hidden"}`));
}

// ---------- institute ----------
export async function instituteSetupAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/manage");
  const { data: inst, error } = await supabase
    .from("institutes")
    .insert({ owner_id: user.id, name: str(form, "name"), town: str(form, "town"), bio: str(form, "bio") })
    .select("id")
    .single();
  if (error || !inst) redirect(`/manage?error=${encodeURIComponent(error ? friendlyError(error) : "تعذّر الحفظ")}`);
  const rooms = Math.min(10, Math.max(1, num(form, "rooms") || 1));
  await supabase.from("rooms").insert(Array.from({ length: rooms }, (_, i) => ({ institute_id: inst.id, name: `قاعة ${i + 1}` })));
  revalidatePath("/manage");
  redirect("/manage?ok=created");
}

export async function newCourseAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/manage/new-course");
  const { data: inst } = await supabase.from("institutes").select("id").eq("owner_id", user.id).maybeSingle();
  if (!inst) redirect("/manage");
  const weekdays = form.getAll("weekdays").map(Number).filter((n) => n >= 0 && n <= 6);
  const count = Math.min(60, Math.max(1, num(form, "sessions")));
  const start = str(form, "start");
  const tm = str(form, "time") || "17:00";
  const room = str(form, "room_id") || null;
  if (!weekdays.length || !start) redirect(`/manage/new-course?error=${encodeURIComponent("اختر يوم البداية وأيام اللقاءات.")}`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(tm)) {
    redirect(`/manage/new-course?error=${encodeURIComponent("اكتب تاريخ البداية والوقت بصيغة صحيحة.")}`);
  }
  const names = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];
  const { data: o, error } = await supabase
    .from("offerings")
    .insert({
      type: "course",
      institute_id: inst.id,
      course_teacher_id: str(form, "teacher_id") || null,
      title: str(form, "title"),
      subject_id: num(form, "subject_id") || null,
      level_id: num(form, "level_id") || null,
      places: form.get("online") === "on" ? ["center", "online"] : ["center"],
      price: num(form, "price"),
      seats: num(form, "seats") || 12,
      schedule_note: `${weekdays.map((w) => names[w]).join(" و")} ${tm}`,
      start_date: start,
      sessions_count: count,
      minutes: [45, 60, 90, 120, 150].includes(num(form, "minutes")) ? num(form, "minutes") : 90,
      default_room_id: room,
    })
    .select("id")
    .single();
  if (error || !o) redirect(`/manage/new-course?error=${encodeURIComponent(error ? friendlyError(error) : "تعذّر الحفظ")}`);
  const days = datesOn(start, weekdays, count);
  const { error: se } = await supabase.from("sessions").insert(
    days.map((d, i) => ({ offering_id: o.id, seq: i + 1, starts_at: fromLocal(d, tm).toISOString(), minutes: [45, 60, 90, 120, 150].includes(num(form, "minutes")) ? num(form, "minutes") : 90, room_id: room }))
  );
  if (se) {
    // No course without its meetings (BUG-09): remove the new, unbooked course and report why.
    const { data: gone } = await supabase.from("offerings").delete().eq("id", o.id).select("id");
    redirect(`/manage/new-course?error=${encodeURIComponent(friendlyError(se) + (gone?.length ? "" : " حُفظت الدورة بلا لقاءات، أكملها من صفحتها."))}`);
  }
  revalidatePath("/manage");
  redirect(`/manage/course/${o.id}`);
}

export async function addStaffAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const { data: inst } = await supabase.from("institutes").select("id,verify").eq("owner_id", user.id).maybeSingle();
  if (!inst) redirect("/manage");
  if (inst.verify !== "verified") redirect(`/manage?error=${encodeURIComponent("يمكن دعوة المعلمين بعد توثيق المعهد.")}#staff`);
  // An invitation: the teacher joins the staff only after accepting it (audit SEC-02).
  const { error } = await supabase.from("institute_teachers").insert({ institute_id: inst.id, teacher_id: str(form, "teacher_id") });
  revalidatePath("/manage");
  const msg = !error ? "" : error.code === "23505" ? "هذا المعلم مدعوّ أو ضمن الطاقم سابقاً." : friendlyError(error);
  redirect(`/manage?${msg ? `error=${encodeURIComponent(msg)}` : "saved=staff_invited"}#staff`);
}

export async function answerStaffInviteAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const accept = str(form, "accept") === "1";
  const { error } = await supabase.rpc("answer_staff_invite", { p_institute: str(form, "institute_id"), p_accept: accept });
  revalidatePath("/teach");
  redirect(`/teach?${error ? `error=${encodeURIComponent(friendlyError(error))}` : accept ? "ok=invite_accepted" : "ok=invite_declined"}#invites`);
}

export async function answerLinkAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/schedule");
  const accept = str(form, "accept") === "1";
  const { error } = await supabase.rpc("accept_booking_link", { p_booking: str(form, "booking_id"), p_accept: accept });
  revalidatePath("/schedule");
  redirect(`/schedule?${error ? `error=${encodeURIComponent(friendlyError(error))}` : accept ? "ok=linked" : "ok=link_declined"}#links`);
}

export async function saveAttendanceAction(form: FormData) {
  const { supabase } = await client();
  const sessionId = str(form, "session_id");
  const rows = [...form.entries()]
    .filter(([k]) => k.startsWith("b_"))
    .map(([k, v]) => ({ session_id: sessionId, booking_id: k.slice(2), present: v === "p" }));
  const path = safePath(str(form, "path"), "/manage");
  const { error } = rows.length ? await supabase.from("attendance").upsert(rows) : { error: null };
  revalidatePath(path);
  redirect(withQ(path, error ? `error=${encodeURIComponent(friendlyError(error))}` : `saved=${rows.length}`));
}

// ---------- photos (private uploads, admin publishing; see lib/photos.ts and migrations 20261105000000/010000) ----------
// Users upload only to the private bucket: a teacher's/institute's new photo waits there (pending_changes.photo_path)
// until the admin publishes it to the public bucket; a profile photo stays private (profiles.avatar_path) and is shown
// through short signed links. Public files: the approved teacher/institute photos (and old public files from before).
type PhotoDb = Awaited<ReturnType<typeof client>>["supabase"];

/** The owner's public photos of this kind that are in use: the live one, and an old public link still waiting in
 * pending_changes (from before private photos). null when it cannot be read: then nothing is deleted. */
async function photosInUse(supabase: PhotoDb, uid: string, kind: PhotoKind): Promise<(string | null)[] | null> {
  if (kind === "profile") {
    const { data, error } = await supabase.from("profiles").select("avatar_url").eq("id", uid).maybeSingle();
    return error ? null : [photoPath(data?.avatar_url)];
  }
  const col = kind === "teacher" ? "photo_url" : "logo_url";
  const [{ data, error }, { data: review, error: rErr }] = await Promise.all([
    kind === "teacher"
      ? supabase.from("teachers").select("id, photo_url").eq("user_id", uid)
      : supabase.from("institutes").select("id, logo_url").eq("owner_id", uid),
    supabase.rpc("my_review_state"),
  ]);
  if (error || rErr) return null;
  const pendingOf = (id: string) => ((review ?? []) as { kind: string; id: string; pending_changes: Record<string, unknown> | null }[])
    .find((r) => r.kind === kind && r.id === id)?.pending_changes ?? null;
  return ((data ?? []) as Record<string, unknown>[]).flatMap((r) => {
    const pending = pendingOf(r.id as string);
    return [photoPath(r[col] as string | null), photoPath(typeof pending?.[col] === "string" ? (pending[col] as string) : null)];
  });
}

/** The owner's private photo of this kind that is in use: the waiting photo (teacher/institute) or the profile photo. */
async function privateInUse(supabase: PhotoDb, uid: string, kind: PhotoKind): Promise<(string | null)[] | null> {
  if (kind === "profile") {
    const { data, error } = await supabase.from("profiles").select("avatar_path").eq("id", uid).maybeSingle();
    return error ? null : [(data?.avatar_path as string | null) ?? null];
  }
  const { data, error } = await supabase.rpc("my_review_state");
  if (error) return null;
  return ((data ?? []) as { kind: string; pending_changes: Record<string, unknown> | null }[])
    .filter((r) => r.kind === kind)
    .map((r) => (typeof r.pending_changes?.photo_path === "string" ? (r.pending_changes.photo_path as string) : null));
}

/** Deletes the owner's own unused photo files of this kind, in both buckets: `extra` (files in use until this change) at
 * once, other unused files once they are older than PHOTO_MIN_AGE_MS. Never a file in use, never another user's file
 * (paths are built from the signed-in user, and the storage policies enforce it again). */
async function tidyPhotos(supabase: PhotoDb, uid: string, kind: PhotoKind, extra: { pub?: string[]; priv?: string[] } = {}): Promise<number> {
  let n = 0;
  const pubUse = await photosInUse(supabase, uid, kind);
  if (pubUse) {
    const { data: files, error } = await supabase.storage.from(PUBLIC_BUCKET).list(uid, { limit: 100 });
    if (!error) {
      const keep = new Set(pubUse.filter(Boolean));
      const doomed = [...new Set([...(extra.pub ?? []), ...photosToDelete({ owner: uid, kind, files: files ?? [], keep: [...keep] })])]
        .filter((p) => p.startsWith(`${uid}/`) && !keep.has(p));
      if (doomed.length && !(await supabase.storage.from(PUBLIC_BUCKET).remove(doomed)).error) n += doomed.length;
    }
  }
  const privUse = await privateInUse(supabase, uid, kind);
  if (privUse) {
    const folder = kind === "profile" ? uid : `${uid}/pending`;
    const { data: files, error } = await supabase.storage.from(PRIVATE_BUCKET).list(folder, { limit: 100 });
    if (!error) {
      const keep = new Set(privUse.filter(Boolean));
      const doomed = [...new Set([...(extra.priv ?? []), ...privateToDelete({ owner: uid, kind, files: files ?? [], keep: [...keep] })])]
        .filter((p) => validPrivatePath(p, { owner: uid, kind }) && !keep.has(p));
      if (doomed.length && !(await supabase.storage.from(PRIVATE_BUCKET).remove(doomed)).error) n += doomed.length;
    }
  }
  return n;
}

const isKind = (k: unknown): k is PhotoKind => PHOTO_KINDS.includes(k as PhotoKind);

/** Saves a newly uploaded private photo (its own unique file in the private bucket). A teacher's or institute's photo
 * waits for the admin, privately: the approved photo keeps showing until the admin publishes the new one. A profile
 * photo is private and applies at once. Returns nothing about other users. */
export async function submitPhotoAction(kind: PhotoKind, path: string): Promise<Result> {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  if (!isKind(kind)) return { error: "طلب غير صالح." };
  if (!validPrivatePath(path, { owner: user.id, kind })) return { error: "تعذّر حفظ الصورة: الملف لا يطابق حسابك." };
  const { data: previous, error } = await supabase.rpc("submit_photo", { p_kind: kind, p_path: path });
  if (error) return { error: friendlyError(error) };
  const priv = typeof previous === "string" && previous !== path ? [previous] : [];
  let pub: string[] = [];
  if (kind === "profile") {
    // an old public profile photo (from before private photos) is no longer used: clear the link and delete the file
    const { data: prof } = await supabase.from("profiles").select("avatar_url").eq("id", user.id).maybeSingle();
    const old = photoPath(prof?.avatar_url as string | null);
    if (prof?.avatar_url) await supabase.from("profiles").update({ avatar_url: null }).eq("id", user.id);
    if (old?.startsWith(`${user.id}/`)) pub = [old];
  }
  await tidyPhotos(supabase, user.id, kind, { pub, priv });
  revalidatePath("/", "layout");
  return { ok: true };
}

/** Removes the account's own photo. A profile photo goes at once (link and file). For a teacher or institute the
 * removal of the live photo waits for admin review like any profile change, so the approved photo stays meanwhile. */
export async function removePhotoAction(kind: PhotoKind): Promise<Result> {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  if (!isKind(kind)) return { error: "طلب غير صالح." };
  const before = (await photosInUse(supabase, user.id, kind)) ?? [];
  const beforePriv = kind === "profile" ? ((await privateInUse(supabase, user.id, kind)) ?? []) : [];
  const { error } =
    kind === "teacher"
      ? await supabase.from("teachers").update({ photo_url: null }).eq("user_id", user.id)
      : kind === "institute"
        ? await supabase.from("institutes").update({ logo_url: null }).eq("owner_id", user.id)
        : await supabase.from("profiles").update({ avatar_url: null, avatar_path: null }).eq("id", user.id);
  if (error) return { error: friendlyError(error) };
  const after = await photosInUse(supabase, user.id, kind);
  if (after) {
    await tidyPhotos(supabase, user.id, kind, {
      pub: noLongerUsed({ owner: user.id, kind, before, after }),
      priv: beforePriv.filter((p): p is string => !!p),
    });
  }
  revalidatePath("/", "layout");
  return { ok: true };
}

/** Clears the owner's unused photo files of this kind (for example a replaced waiting photo, or an old public photo
 * after a new one was published). Called when the owner opens a page with their photo box; changes nothing visible. */
export async function tidyPhotosAction(kind: PhotoKind): Promise<Result> {
  const { supabase, user } = await client();
  if (!user || !isKind(kind)) return { ok: true, count: 0 };
  return { ok: true, count: await tidyPhotos(supabase, user.id, kind) };
}

/** Admin: publishes an approved waiting photo. Copies the private file to a new name in the owner's public folder (with
 * the admin's own session; the storage policies allow exactly that), sets it live with admin_publish_photo (which checks
 * the waiting path and the copied file), then deletes the private original and the previous public photo. If setting
 * it live fails, the copy is deleted again, so no public file is left behind. */
async function publishWaitingPhoto(supabase: PhotoDb, kind: "teacher" | "institute", id: string, waiting: string): Promise<string | null> {
  const dest = publishedPath(waiting, kind);
  if (!dest) return "الصورة المنتظرة غير صالحة.";
  const { error: cpErr } = await supabase.storage.from(PRIVATE_BUCKET).copy(waiting, dest, { destinationBucket: PUBLIC_BUCKET });
  if (cpErr) return `تعذّر نشر الصورة: ${cpErr.message}`;
  const url = supabase.storage.from(PUBLIC_BUCKET).getPublicUrl(dest).data.publicUrl;
  const { data: previous, error } = await supabase.rpc("admin_publish_photo", { p_kind: kind, p_id: id, p_path: waiting, p_url: url });
  if (error) {
    await supabase.storage.from(PUBLIC_BUCKET).remove([dest]);
    return friendlyError(error);
  }
  await supabase.storage.from(PRIVATE_BUCKET).remove([waiting]);
  const owner = privateOwner(waiting, kind);
  const old = photoPath(typeof previous === "string" ? previous : null);
  if (owner && old && old.startsWith(`${owner}/`) && old !== dest) await supabase.storage.from(PUBLIC_BUCKET).remove([old]);
  return null;
}

/** The private photo waiting for the admin in this review item, if any (read with the admin's own rights). */
async function waitingPhotoOf(supabase: PhotoDb, kind: string, id: string): Promise<string | null> {
  if (kind !== "teacher" && kind !== "institute") return null;
  const { data } = await supabase.rpc("admin_review_queue");
  const row = ((data ?? []) as { kind: string; id: string; changes: Record<string, unknown> | null }[]).find((r) => r.kind === kind && r.id === id);
  const p = row?.changes?.photo_path;
  return typeof p === "string" && privateOwner(p, kind) ? p : null;
}

export async function updateTeacherAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach");
  // Check everything first; nothing is written when a field is wrong (BUG-10: a bad video link used to erase the saved one).
  const video = str(form, "intro_video");
  if (video && !/^https:\/\/\S{6,290}$/.test(video)) redirect(`/teach?error=${encodeURIComponent("رابط الفيديو غير صحيح. انسخ الرابط الكامل من YouTube (يبدأ بـ https://).")}#profile`);
  const wa = form.has("whatsapp") && str(form, "whatsapp") ? cleanMobile(str(form, "whatsapp")) : null;
  if (form.has("whatsapp") && str(form, "whatsapp") && !wa) redirect(`/teach?error=${encodeURIComponent("رقم الواتساب غير صحيح. اكتب رقم جوال مثل 050-1234567.")}#profile`);
  const { error } = await supabase
    .from("teachers")
    .update({
      name: str(form, "name"),
      town: str(form, "town"),
      subject_id: num(form, "subject_id") || null,
      bio: str(form, "bio"),
      years: num(form, "years"),
      is_school_teacher: form.get("school") === "on",
      intro_video_url: video || null,
      ...(form.has("whatsapp") ? { whatsapp: wa } : {}),
    })
    .eq("user_id", user.id);
  if (error) redirect(`/teach?error=${encodeURIComponent(friendlyError(error))}#profile`);
  if (form.has("bit_phone")) {
    const { error: bitErr } = await supabase.rpc("set_bit_phone", { p_phone: str(form, "bit_phone"), p_institute: false });
    if (bitErr) redirect(`/teach?error=${encodeURIComponent(friendlyError(bitErr))}#profile`);
  }
  revalidatePath("/teach");
  redirect("/teach?ok=profile");
}

export async function updateInstituteAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/manage");
  await supabase.from("institutes").update({ name: str(form, "name"), town: str(form, "town"), bio: str(form, "bio") }).eq("owner_id", user.id);
  if (form.has("whatsapp")) {
    const wa = str(form, "whatsapp") ? cleanMobile(str(form, "whatsapp")) : null;
    if (str(form, "whatsapp") && !wa) redirect(`/manage?error=${encodeURIComponent("رقم الواتساب غير صحيح. اكتب رقم جوال مثل 050-1234567.")}`);
    await supabase.from("institutes").update({ whatsapp: wa }).eq("owner_id", user.id);
  }
  if (form.has("bit_phone")) {
    const { error: bitErr } = await supabase.rpc("set_bit_phone", { p_phone: str(form, "bit_phone"), p_institute: true });
    if (bitErr) redirect(`/manage?error=${encodeURIComponent(bitErr.message)}`);
  }
  revalidatePath("/manage");
  redirect("/manage?ok=profile");
}

// ---------- admin ----------
export async function adminVerifyAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const { error } = await supabase.rpc("admin_verify", {
    p_kind: str(form, "kind"),
    p_id: str(form, "id"),
    p_status: str(form, "status"),
  });
  revalidatePath("/admin");
  if (error) redirect(`/admin?error=${encodeURIComponent(friendlyError(error))}`);
}

// ---------- meeting / content link ----------
export async function saveLinkAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const id = str(form, "offering_id");
  const url = str(form, "url");
  const path = safePath(str(form, "path"), `/manage/course/${id}`);
  if (!url) {
    await supabase.from("offering_links").delete().eq("offering_id", id);
  } else {
    if (!/^https?:\/\//i.test(url)) redirect(`${path}?error=${encodeURIComponent("الرابط يجب أن يبدأ بـ https://")}`);
    const { error } = await supabase.from("offering_links").upsert({ offering_id: id, url, note: str(form, "note") || null, updated_at: new Date().toISOString() });
    if (error) redirect(`${path}?error=${encodeURIComponent(friendlyError(error))}`);
  }
  revalidatePath(path);
  redirect(`${path}?saved=link`);
}

// ---------- teacher availability ----------
export async function saveAvailabilityAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach");
  // "9:00" or "09:00:00" -> "09:00"; the database validates the rest.
  const hhmm = (v: string) => { const m = v.match(/^(\d{1,2}):(\d{2})/); return m ? `${m[1].padStart(2, "0")}:${m[2]}` : v; };
  const rows: { weekday: number; start: string; end: string }[] = [];
  for (let w = 0; w <= 6; w++) {
    if (form.get(`on_${w}`) !== "on") continue;
    for (const [a, b] of [[str(form, `from_${w}`), str(form, `to_${w}`)], [str(form, `from2_${w}`), str(form, `to2_${w}`)]]) {
      if (a && b) rows.push({ weekday: w, start: hhmm(a), end: hhmm(b) });
    }
  }
  const buffer = [0, 5, 10, 15, 30].includes(num(form, "buffer")) ? num(form, "buffer") : 0;
  // One transaction in the database: either all the new hours are saved, or the old ones stay (BUG-04).
  const { data, error } = await supabase.rpc("replace_availability", { p_rows: rows, p_buffer: buffer });
  revalidatePath("/teach");
  if (error) redirect(`/teach?error=${encodeURIComponent(friendlyError(error))}#hours`);
  redirect(`/teach?ok=hours&n=${data ?? 0}#hours`);
}

// ---------- editing an offer ----------
export async function updateOfferingAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const id = str(form, "id");
  const path = `/manage/course/${id}`;
  const { data: o } = await supabase.from("offerings").select("type,places").eq("id", id).maybeSingle();
  if (!o) redirect(path);
  const title = str(form, "title");
  const price = num(form, "price");
  if (title.length < 3) redirect(`${path}?error=${encodeURIComponent("العنوان قصير جداً.")}`);
  if (!(price >= 0)) redirect(`${path}?error=${encodeURIComponent("السعر غير صالح.")}`);
  const row: Record<string, unknown> = {
    title,
    price,
    subject_id: num(form, "subject_id") || null,
    level_id: num(form, "level_id") || null,
  };
  const placeSel = str(form, "place");
  if (o.type === "private" || o.type === "group") {
    row.places = placeSel === "both" ? ["home", "online"] : [(placeSel || "home") as Place];
  }
  if (o.type === "course") {
    row.places = form.get("online") === "on" ? ["center", "online"] : ["center"];
    row.course_teacher_id = str(form, "teacher_id") || null;
  }
  if (o.type === "group" || o.type === "course") row.seats = num(form, "seats") || null;
  if (o.type === "recorded") row.lessons_count = num(form, "lessons") || null;
  if (o.type !== "recorded" && [30, 45, 60, 90, 120, 150].includes(num(form, "minutes"))) row.minutes = num(form, "minutes");
  if (o.type === "private") row.auto_confirm = form.get("auto_confirm") === "on";
  if (o.type === "private" || o.type === "group") row.allow_weekly = form.get("allow_weekly") === "on";
  Object.assign(row, offerExtras(form, o.type));
  if (form.get("package_on") === "on" && !row.package_enabled) redirect(`${path}?error=${encodeURIComponent("لتفعيل الرزمة أدخل عدد الحصص (2 إلى 50) وسعر الرزمة.")}&edit=1`);
  const { error } = await supabase.from("offerings").update(row).eq("id", id);
  revalidatePath(path);
  revalidatePath(`/offer/${id}`);
  redirect(`${path}?${error ? `error=${encodeURIComponent(friendlyError(error))}` : "saved=offer"}`);
}

// ---------- messages ----------
export async function startConversationAction(form: FormData) {
  const { supabase, user } = await client();
  const back = safePath(str(form, "back"), "/");
  if (!user) redirect(`/login?next=${encodeURIComponent(back)}`);
  const { data, error } = await supabase.rpc("start_conversation", {
    p_teacher: str(form, "teacher_id") || null,
    p_institute: str(form, "institute_id") || null,
  });
  if (error || !data) redirect(`/messages?error=${encodeURIComponent(error ? friendlyError(error) : "تعذّر فتح المحادثة")}`);
  redirect(`/messages/${data}`);
}

export async function startBookingConversationAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const { data, error } = await supabase.rpc("start_conversation_for_booking", { p_booking: str(form, "booking_id") });
  if (error || !data) redirect(`/messages?error=${encodeURIComponent(error ? friendlyError(error) : "تعذّر فتح المحادثة")}`);
  redirect(`/messages/${data}`);
}

export async function sendMessageAction(conversationId: string, body: string): Promise<Result> {
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const text = body.trim();
  if (!text) return { error: "اكتب رسالة." };
  if (text.length > 2000) return { error: "الرسالة طويلة جداً." };
  const { error } = await supabase.from("messages").insert({ conversation_id: conversationId, body: text });
  if (error) return { error: "تعذّر الإرسال، حاول مرة أخرى." };
  return { ok: true };
}

export async function reportConversationAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const id = str(form, "conversation_id");
  await supabase.from("conversation_reports").insert({ conversation_id: id, reason: str(form, "reason") || null });
  redirect(`/messages/${id}?reported=1`);
}

export async function resolveReportAction(form: FormData) {
  const { supabase } = await client();
  await supabase.from("conversation_reports").update({ resolved: true }).eq("id", str(form, "id"));
  revalidatePath("/admin");
}

// ---------- reports and moderation ----------
export async function submitReportAction(form: FormData) {
  const { supabase, user } = await client();
  const back = safePath(str(form, "back"), "/");
  if (!user) redirect(`/login?next=${encodeURIComponent(back)}`);
  const { error } = await supabase.from("reports").insert({
    target_type: str(form, "target_type"),
    target_id: str(form, "target_id"),
    reason: str(form, "reason") || "other",
    details: str(form, "details").slice(0, 1000) || null,
  });
  redirect(withQ(back, `${error ? `report_error=${encodeURIComponent(friendlyError(error))}` : "reported=1"}`));
}

export async function adminSetStatusAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = safePath(str(form, "back"), "/admin");
  const { error } = await supabase.rpc("admin_set_user_status", {
    p_user: str(form, "user_id"),
    p_status: str(form, "status"),
    p_days: str(form, "status") === "suspended" ? num(form, "days") || 7 : null,
    p_reason: str(form, "reason") || null,
  });
  revalidatePath(back);
  redirect(withQ(back, `${error ? `error=${encodeURIComponent(friendlyError(error))}` : "done=status"}`));
}

export async function adminHideAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = safePath(str(form, "back"), "/admin");
  const { error } = await supabase.rpc("admin_hide", {
    p_kind: str(form, "kind"),
    p_id: str(form, "id"),
    p_hidden: str(form, "hidden") === "1",
    p_reason: str(form, "reason") || null,
  });
  revalidatePath(back);
  redirect(withQ(back, `${error ? `error=${encodeURIComponent(friendlyError(error))}` : "done=hide"}`));
}

export async function adminCloseReportAction(form: FormData) {
  const { supabase } = await client();
  const { error } = await supabase.rpc("admin_close_report", {
    p_report: str(form, "id"),
    p_status: str(form, "status"),
    p_note: str(form, "note") || null,
  });
  revalidatePath("/admin");
  redirect(`/admin?tab=reports${error ? `&error=${encodeURIComponent(friendlyError(error))}` : "&done=report"}`);
}

export async function cancelSeriesAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = safePath(str(form, "back"), "/schedule");
  const { data, error } = await supabase.rpc("cancel_series", { p_series: str(form, "id") });
  revalidatePath(back);
  redirect(withQ(back, `${error ? `error=${encodeURIComponent(friendlyError(error))}` : `cancelled_series=${data}`}`));
}

// ---------- waiting list ----------
export async function joinWaitlistAction(input: { offeringId: string; childId?: string | null; note?: string }): Promise<Result> {
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const { data, error } = await supabase.rpc("join_waitlist", {
    p_offering: input.offeringId,
    p_child: input.childId || null,
    p_note: (input.note ?? "").slice(0, 300) || null,
  });
  if (error) return { error: friendlyError(error) };
  revalidatePath(`/offer/${input.offeringId}`);
  revalidatePath("/schedule");
  return { ok: true, count: Number(data) };
}

export async function leaveWaitlistAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = safePath(str(form, "back"), "/schedule");
  const { error } = await supabase.rpc("leave_waitlist", { p_id: str(form, "id") });
  revalidatePath(back);
  redirect(withQ(back, `${error ? `error=${encodeURIComponent(friendlyError(error))}` : "left=1"}`));
}

export async function respondWaitlistAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = safePath(str(form, "back"), "/teach");
  const accept = str(form, "accept") === "1";
  const { data, error } = await supabase.rpc("respond_waitlist", { p_id: str(form, "id"), p_accept: accept, p_reply: str(form, "reply") || null });
  revalidateTag("catalog");
  revalidatePath(back);
  if (error) redirect(withQ(back, `error=${encodeURIComponent(friendlyError(error))}`) + "#waitlist");
  if (data) redirect(`/messages/${data}`);
  redirect(withQ(back, `wl=${accept ? "accepted" : "declined"}`) + "#waitlist");
}

// ---------- phone notifications & reminders ----------
export async function savePushSubscriptionAction(sub: { endpoint: string; p256dh: string; auth: string }): Promise<Result> {
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const { error } = await supabase.rpc("save_push_subscription", { p_endpoint: sub.endpoint, p_p256dh: sub.p256dh, p_auth: sub.auth });
  return error ? { error: friendlyError(error) } : { ok: true };
}

export async function removePushSubscriptionAction(endpoint: string): Promise<Result> {
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  await supabase.rpc("remove_push_subscription", { p_endpoint: endpoint });
  return { ok: true };
}

export async function setEmailRemindersAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  await supabase.from("profiles").update({ email_reminders: str(form, "on") === "1" }).eq("id", user.id);
  revalidatePath("/notifications");
  redirect("/notifications?ok=email");
}

// ---------- teacher calendar ----------
function calBack(form: FormData, q: Record<string, string>) {
  const day = str(form, "day");
  const p = new URLSearchParams({ ...(day ? { day } : {}), ...q });
  return `/teach/calendar?${p}`;
}
function formInstant(form: FormData, dayKey = "date", timeKey = "time") {
  const d = str(form, dayKey);
  const t = str(form, timeKey);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(d) || !/^\d{2}:\d{2}$/.test(t)) return null;
  return fromLocal(d, t).toISOString();
}

export async function teacherBlockAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach/calendar");
  const at = formInstant(form);
  if (!at) redirect(calBack(form, { error: "اختر اليوم والساعة." }));
  const { data, error } = await supabase.rpc("teacher_block", {
    p_starts_at: at, p_minutes: Math.min(Math.max(num(form, "minutes") || 60, 15), 600), p_note: str(form, "note") || null, p_weeks: str(form, "weekly") === "1" ? 8 : 1,
  });
  revalidateTag("catalog");
  if (error) redirect(calBack(form, { error: friendlyError(error) }));
  redirect(calBack(form, { ok: Number(data) > 1 ? `blocked:${data}` : "blocked" }));
}

export async function teacherUnblockAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach/calendar");
  const { error } = await supabase.rpc("teacher_unblock", { p_block: str(form, "id"), p_all: str(form, "all") === "1" });
  revalidateTag("catalog");
  redirect(calBack(form, error ? { error: friendlyError(error) } : { ok: "opened" }));
}

export async function teacherAddBookingAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach/calendar");
  const at = formInstant(form);
  const [student, child] = str(form, "student").split("|");
  if (!at || !student) redirect(calBack(form, { error: "اختر الطالب والموعد." }));
  const { data, error } = await supabase.rpc("teacher_add_booking", {
    p_offering: str(form, "offering_id"), p_student: student, p_child: child || null, p_starts_at: at, p_weekly: str(form, "weekly") === "1",
  });
  revalidateTag("catalog");
  if (error) redirect(calBack(form, { error: friendlyError(error) }));
  const r = data as { created: number; skipped: string[] };
  redirect(calBack(form, { ok: "added", n: String(r.created), ...(r.skipped?.length ? { skipped: r.skipped.join("، ") } : {}) }));
}

export async function teacherMoveBookingAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach/calendar");
  const at = formInstant(form);
  if (!at) redirect(calBack(form, { error: "اختر اليوم والساعة الجديدين." }));
  const { error } = await supabase.rpc("teacher_move_booking", {
    p_booking: str(form, "id"), p_new_start: at, p_scope: str(form, "scope") === "following" ? "following" : "one", p_note: str(form, "note") || null,
  });
  revalidateTag("catalog");
  if (error) redirect(calBack(form, { error: friendlyError(error) }));
  redirect(calBack(form, { ok: "moved", day: str(form, "date") }));
}

export async function teacherCancelBookingAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach/calendar");
  const { error } = await supabase.rpc("teacher_cancel_booking", {
    p_booking: str(form, "id"), p_scope: str(form, "scope") === "series" ? "series" : "one", p_reason: str(form, "reason") || null,
  });
  revalidateTag("catalog");
  revalidatePath("/teach");
  redirect(calBack(form, error ? { error: friendlyError(error) } : { ok: "cancelled" }));
}

// ---------- lesson packages ----------
export async function buyPackageAction(form: FormData) {
  const { supabase, user } = await client();
  const id = str(form, "offering_id");
  if (!user) redirect(`/login?next=/offer/${id}`);
  const who = str(form, "who");
  const { error } = await supabase.rpc("buy_package", { p_offering: id, p_child: who && who !== "self" ? who : null, p_pay: str(form, "pay") || "bit" });
  revalidatePath(`/offer/${id}`);
  redirect(`/offer/${id}?${error ? `package_error=${encodeURIComponent(friendlyError(error))}` : "package=1"}`);
}

export async function cancelPackageAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = safePath(str(form, "back"), "/teach");
  const { error } = await supabase.rpc("cancel_package", { p_package: str(form, "id") });
  revalidatePath(back);
  redirect(withQ(back, `${error ? `error=${encodeURIComponent(friendlyError(error))}` : "saved=package"}`));
}

// ---------- lesson reports ----------
const rating = (form: FormData, k: string) => {
  const n = num(form, k);
  return n >= 1 && n <= 5 ? n : null;
};

export async function writeReportAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach");
  const booking = str(form, "booking_id");
  const back = safePath(str(form, "back"), "/teach");
  const { error } = await supabase.rpc("write_lesson_report", {
    p_booking: booking,
    p_session: str(form, "session_id") || null,
    p_summary: str(form, "summary") || null,
    p_homework: str(form, "homework") || null,
    p_understanding: rating(form, "understanding"),
    p_participation: rating(form, "participation"),
    p_note: str(form, "note") || null,
    p_present: str(form, "absent") !== "on",
  });
  if (error) redirect(`/teach/report?booking=${booking}&error=${encodeURIComponent(friendlyError(error))}`);
  revalidatePath("/teach");
  redirect(withQ(back, `ok=report`));
}

export async function writeSessionReportsAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach");
  const session = str(form, "session_id");
  const back = safePath(str(form, "back"), "/teach");
  const n = Math.min(num(form, "count"), 200);
  const items = Array.from({ length: n }, (_, i) => ({
    booking_id: str(form, `b_${i}`),
    present: str(form, `absent_${i}`) !== "on",
    understanding: rating(form, `u_${i}`),
    participation: rating(form, `p_${i}`),
    note: str(form, `n_${i}`) || null,
  })).filter((x) => x.booking_id);
  const { error } = await supabase.rpc("write_session_reports", {
    p_session: session, p_summary: str(form, "summary"), p_homework: str(form, "homework") || null, p_items: items,
  });
  if (error) redirect(`/teach/report?session=${session}&error=${encodeURIComponent(friendlyError(error))}`);
  revalidatePath("/teach");
  redirect(withQ(back, `ok=report`));
}

// ---------- payments (cash / Bit, no gateway) ----------
function backTo(form: FormData, fallback: string) {
  return safePath(str(form, "back"), fallback);
}
const withQ = (url: string, q: string) => {
  const [path, hash] = url.split("#");
  return `${path}${path.includes("?") ? "&" : "?"}${q}${hash ? `#${hash}` : ""}`;
};

export async function reportPaymentAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/schedule");
  const { error } = await supabase.rpc("report_payment", { p_booking: str(form, "booking_id") || null, p_package: str(form, "package_id") || null });
  revalidatePath(back.split("?")[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "paid_reported=1"));
}

export async function confirmPaymentAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/teach#payments");
  const { error } = await supabase.rpc("confirm_payment", {
    p_booking: str(form, "booking_id") || null, p_package: str(form, "package_id") || null, p_received: str(form, "received") !== "0",
  });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "ok=payment"));
}

// ---------- admin content review ----------
export async function adminReviewAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const kind = str(form, "kind"), id = str(form, "id"), approve = str(form, "approve") === "1";
  // a teacher's/institute's new photo waits in the private bucket: on approval it is published (copied to the public
  // bucket) only after the other changes are approved; on rejection its private file is deleted at once
  const waiting = await waitingPhotoOf(supabase, kind, id);
  const { error } = await supabase.rpc("admin_review", { p_kind: kind, p_id: id, p_approve: approve, p_note: str(form, "note") || null });
  let photoError: string | null = null;
  if (!error && waiting && (kind === "teacher" || kind === "institute")) {
    if (approve) photoError = await publishWaitingPhoto(supabase, kind, id, waiting);
    else await supabase.storage.from(PRIVATE_BUCKET).remove([waiting]);
  }
  revalidatePath("/admin");
  revalidatePath("/", "layout");
  const msg = error ? friendlyError(error) : photoError;
  redirect(`/admin?tab=review&${msg ? `error=${encodeURIComponent(msg)}` : "done=1"}`);
}

// ---------- subscriptions (teachers & institutes pay the platform) ----------
export async function requestSubscriptionAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/teach#subscription");
  const { error } = await supabase.rpc("request_subscription", { p_plan: str(form, "plan") });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "sub=chosen"));
}

export async function reportSubscriptionAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/teach#subscription");
  const { error } = await supabase.rpc("report_subscription_payment", { p_id: str(form, "id") });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "sub=reported"));
}

export async function adminSubscriptionAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const op = str(form, "op");
  let error: { message: string } | null = null;
  if (op === "activate" || op === "reject") {
    ({ error } = await supabase.rpc("admin_activate_subscription", { p_id: str(form, "id"), p_approve: op === "activate", p_note: str(form, "note") || null }));
  } else if (op === "grant") {
    const [kind, id] = str(form, "owner").split(":");
    ({ error } = await supabase.rpc("admin_grant_subscription", {
      p_teacher: kind === "teacher" ? id : null, p_institute: kind === "institute" ? id : null, p_months: num(form, "months"), p_note: str(form, "note") || null,
    }));
  } else if (op === "setting") {
    ({ error } = await supabase.rpc("admin_set_setting", { p_key: str(form, "key"), p_value: str(form, "value") }));
    revalidateTag("settings");
  } else if (op === "plan") {
    ({ error } = await supabase.rpc("admin_set_plan", { p_code: str(form, "code"), p_price: num(form, "price"), p_active: form.get("active") === "on" }));
  } else if (op === "demo") {
    ({ error } = await supabase.rpc("admin_demo_visible", { p_visible: str(form, "visible") === "1" }));
  }
  revalidatePath("/admin");
  revalidatePath("/");
  redirect(`/admin?tab=subs&${error ? `error=${encodeURIComponent(friendlyError(error))}` : "done=1"}`);
}

// ---------- ratings ----------
export async function leaveReviewAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  const booking = str(form, "booking_id");
  if (!user) redirect(`/login?next=/review?booking=${booking}`);
  const { error } = await supabase.rpc("leave_review", { p_booking: booking, p_stars: num(form, "stars"), p_body: str(form, "body") || null });
  if (error) redirect(`/review?booking=${booking}&error=${encodeURIComponent(friendlyError(error))}`);
  redirect(`/review?booking=${booking}&done=1`);
}

export async function replyReviewAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/teach#reviews");
  const { error } = await supabase.rpc("reply_review", { p_review: str(form, "id"), p_reply: str(form, "reply") });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "ok=reply"));
}

export async function adminHideReviewAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const { error } = await supabase.rpc("admin_hide_review", { p_review: str(form, "id"), p_hidden: str(form, "hidden") === "1" });
  const back = backTo(form, "/admin");
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "done=1"));
}

// ---------- delete my account ----------
export async function deleteAccountAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const { error } = await supabase.rpc("delete_my_account", { p_confirm: str(form, "confirm") });
  if (error) redirect(`/account?error=${encodeURIComponent(friendlyError(error))}#delete`);
  await supabase.auth.signOut();
  redirect("/?deleted=1");
}

// ---------- operations: meetings, walk-ins, staff, vacation ----------
export async function cancelSessionAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/manage");
  const { error } = await supabase.rpc("cancel_session", { p_session: str(form, "session_id"), p_reason: str(form, "reason") || null, p_makeup: form.get("makeup") === "on" });
  revalidatePath(back.split(/[?#]/)[0]);
  revalidatePath("/schedule");
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "ok=cancelled"));
}

export async function enrollWalkInAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/manage");
  const { data, error } = await supabase.rpc("institute_enroll", {
    p_offering: str(form, "offering_id"), p_name: str(form, "name"), p_phone: str(form, "phone") || null,
    p_pay: str(form, "pay") || "cash", p_paid: form.get("paid") === "on",
  });
  revalidatePath(back.split(/[?#]/)[0]);
  if (error) redirect(withQ(back, `enroll=1&error=${encodeURIComponent(friendlyError(error))}`));
  // Whether the phone has a Classi account is not revealed (audit SEC-03); the parent links it from their side.
  redirect(withQ(back, `ok=enrolled&id=${data}`));
}

export async function linkWalkInAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/manage");
  const { error } = await supabase.rpc("institute_link_booking", { p_booking: str(form, "booking_id") });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "ok=link_requested"));
}

export async function removeStaffAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const { error } = await supabase.rpc("institute_remove_staff", { p_teacher: str(form, "teacher_id") });
  revalidatePath("/manage");
  redirect(`/manage?${error ? `error=${encodeURIComponent(friendlyError(error))}` : "saved=staff_removed"}#staff`);
}

export async function teacherVacationAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const from = str(form, "from");
  const to = str(form, "to") || from;
  const { data, error } = await supabase.rpc("teacher_vacation", { p_from: from, p_to: to, p_note: str(form, "note") || null });
  revalidatePath("/teach/calendar");
  redirect(`/teach/calendar?day=${from}&${error ? `error=${encodeURIComponent(friendlyError(error))}` : `ok=vacation&n=${data ?? 0}`}`);
}

// ---------- admin operations ----------
export async function adminCancelBookingAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = safePath(str(form, "back"), "/admin?tab=ops");
  const { error } = await supabase.rpc("admin_cancel_booking", { p_booking: str(form, "booking_id"), p_reason: str(form, "reason") });
  revalidatePath("/admin");
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "done=cancel"));
}

export async function adminSetPaymentAction(form: FormData) {
  const { supabase } = await client();
  const back = safePath(str(form, "back"), "/admin?tab=ops");
  const { error } = await supabase.rpc("admin_set_payment", { p_booking: str(form, "booking_id"), p_status: str(form, "status"), p_reason: str(form, "reason") });
  revalidatePath("/admin");
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "done=payment"));
}

export async function adminMessageAction(form: FormData) {
  const { supabase } = await client();
  const back = safePath(str(form, "back"), "/admin");
  const { error } = await supabase.rpc("admin_message", { p_user: str(form, "user_id"), p_body: str(form, "body") });
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "done=message"));
}

export async function adminEditOfferAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = safePath(str(form, "back"), "/admin");
  const { error } = await supabase.rpc("admin_edit_offer", { p_offering: str(form, "id"), p_title: str(form, "title"), p_reason: str(form, "reason") || null });
  revalidatePath(back.split("?")[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(friendlyError(error))}` : "done=edit"));
}
