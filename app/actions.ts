"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { fromLocal } from "@/lib/format";
import { datesOn, nextDays } from "@/lib/dates";
import type { OfferingType, Place, Role } from "@/lib/types";

type Result = { error?: string; ok?: boolean; count?: number };

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
}): Promise<Result> {
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً لإتمام الحجز." };
  const { error } = await supabase.rpc("create_booking", {
    p_offering: input.offeringId,
    p_child: input.childId || null,
    p_starts_at: input.startsAt || null,
    p_session: input.sessionId || null,
    p_pay: input.pay,
    p_weekly: !!input.weekly,
    p_mode: input.mode || null,
  });
  if (error) return { error: error.message };
  revalidatePath("/schedule");
  return { ok: true };
}

export async function cancelBookingAction(form: FormData) {
  const { supabase } = await client();
  const { error } = await supabase.rpc("cancel_booking", { p_booking: str(form, "id") });
  revalidatePath("/schedule");
  if (error) redirect(`/schedule?error=${encodeURIComponent(error.message)}`);
}

export async function respondAction(form: FormData) {
  const { supabase } = await client();
  const { error } = await supabase.rpc("respond_booking", { p_booking: str(form, "id"), p_accept: str(form, "accept") === "1" });
  revalidatePath("/teach");
  if (error) redirect(`/teach?error=${encodeURIComponent(error.message)}`);
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
  if (error) return { error: error.message };
  revalidatePath(input.path);
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
  await supabase.from("profiles").update({ full_name: str(form, "full_name"), town: str(form, "town") || null }).eq("id", user.id);
  revalidatePath("/account");
}

export async function addChildAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const name = str(form, "name");
  if (!name) return;
  await supabase.from("children").insert({ guardian_id: user.id, name, grade: str(form, "grade") || null });
  revalidatePath("/account");
}

export async function removeChildAction(form: FormData) {
  const { supabase } = await client();
  await supabase.from("children").delete().eq("id", str(form, "id"));
  revalidatePath("/account");
}

// ---------- teacher ----------
export async function teacherSetupAction(form: FormData) {
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
  if (error) redirect(`/teach?error=${encodeURIComponent("تعذّر حفظ الملف: " + error.message)}`);
  revalidatePath("/teach");
  redirect("/teach");
}

export async function newOfferingAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach/new");
  const { data: t } = await supabase.from("teachers").select("id").eq("user_id", user.id).maybeSingle();
  if (!t) redirect("/teach");
  const type = str(form, "type") as OfferingType;
  const placeSel = str(form, "place");
  const places: Place[] = type === "recorded" ? ["online"] : placeSel === "both" ? ["home", "online"] : [(placeSel || "home") as Place];
  const weekday = num(form, "weekday");
  const tm = str(form, "time") || "18:00";
  const row: Record<string, unknown> = {
    type,
    teacher_id: t.id,
    title: str(form, "title"),
    subject_id: num(form, "subject_id") || null,
    level_id: num(form, "level_id") || null,
    places,
    price: num(form, "price"),
    minutes: type === "group" ? 90 : type === "recorded" ? 0 : 60,
  };
  if (type === "group") {
    row.seats = num(form, "seats") || 6;
    row.schedule_note = `كل ${["أحد", "اثنين", "ثلاثاء", "أربعاء", "خميس", "جمعة"][weekday]} ${tm}`;
  }
  if (type === "recorded") row.lessons_count = num(form, "lessons") || null;
  const link = str(form, "link");
  if (link && !/^https?:\/\//i.test(link)) redirect(`/teach/new?error=${encodeURIComponent("الرابط يجب أن يبدأ بـ https://")}`);
  const { data: o, error } = await supabase.from("offerings").insert(row).select("id").single();
  if (error || !o) redirect(`/teach/new?error=${encodeURIComponent(error?.message ?? "تعذّر النشر")}`);
  if (link) await supabase.from("offering_links").upsert({ offering_id: o.id, url: link });
  if (type === "group") {
    const days = datesOn(nextDays(1)[0], [weekday], 8);
    await supabase.from("sessions").insert(
      days.map((d, i) => ({ offering_id: o.id, seq: i + 1, starts_at: fromLocal(d, tm).toISOString(), minutes: 90 }))
    );
  }
  revalidatePath("/teach");
  redirect("/teach?ok=published");
}

export async function toggleOfferingAction(form: FormData) {
  const { supabase } = await client();
  await supabase.from("offerings").update({ active: str(form, "active") === "1" }).eq("id", str(form, "id"));
  revalidatePath(str(form, "path") || "/teach");
}

// ---------- institute ----------
export async function instituteSetupAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/manage");
  const { data: inst, error } = await supabase
    .from("institutes")
    .insert({ owner_id: user.id, name: str(form, "name"), town: str(form, "town"), bio: str(form, "bio") })
    .select("id")
    .single();
  if (error || !inst) redirect(`/manage?error=${encodeURIComponent("تعذّر الحفظ: " + (error?.message ?? ""))}`);
  const rooms = Math.min(10, Math.max(1, num(form, "rooms") || 1));
  await supabase.from("rooms").insert(Array.from({ length: rooms }, (_, i) => ({ institute_id: inst.id, name: `قاعة ${i + 1}` })));
  revalidatePath("/manage");
  redirect("/manage");
}

export async function newCourseAction(form: FormData) {
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
      minutes: 90,
      default_room_id: room,
    })
    .select("id")
    .single();
  if (error || !o) redirect(`/manage/new-course?error=${encodeURIComponent(error?.message ?? "تعذّر الحفظ")}`);
  const days = datesOn(start, weekdays, count);
  await supabase.from("sessions").insert(
    days.map((d, i) => ({ offering_id: o.id, seq: i + 1, starts_at: fromLocal(d, tm).toISOString(), minutes: 90, room_id: room }))
  );
  revalidatePath("/manage");
  redirect(`/manage/course/${o.id}`);
}

export async function addStaffAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const { data: inst } = await supabase.from("institutes").select("id").eq("owner_id", user.id).maybeSingle();
  if (!inst) redirect("/manage");
  await supabase.from("institute_teachers").upsert({ institute_id: inst.id, teacher_id: str(form, "teacher_id") });
  revalidatePath("/manage");
}

export async function saveAttendanceAction(form: FormData) {
  const { supabase } = await client();
  const sessionId = str(form, "session_id");
  const rows = [...form.entries()]
    .filter(([k]) => k.startsWith("b_"))
    .map(([k, v]) => ({ session_id: sessionId, booking_id: k.slice(2), present: v === "p" }));
  if (rows.length) await supabase.from("attendance").upsert(rows);
  revalidatePath(str(form, "path"));
  redirect(`${str(form, "path")}?saved=1`);
}

// ---------- photos ----------
export async function savePhotoAction(kind: "teacher" | "institute" | "profile", url: string): Promise<Result> {
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const base = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/storage/v1/object/public/avatars/${user.id}/`;
  if (!url.startsWith(base)) return { error: "رابط الصورة غير صالح." };
  const { error } =
    kind === "teacher"
      ? await supabase.from("teachers").update({ photo_url: url }).eq("user_id", user.id)
      : kind === "institute"
        ? await supabase.from("institutes").update({ logo_url: url }).eq("owner_id", user.id)
        : await supabase.from("profiles").update({ avatar_url: url }).eq("id", user.id);
  if (error) return { error: error.message };
  revalidatePath("/", "layout");
  return { ok: true };
}

export async function updateTeacherAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach");
  await supabase
    .from("teachers")
    .update({
      name: str(form, "name"),
      town: str(form, "town"),
      subject_id: num(form, "subject_id") || null,
      bio: str(form, "bio"),
      years: num(form, "years"),
      is_school_teacher: form.get("school") === "on",
    })
    .eq("user_id", user.id);
  revalidatePath("/teach");
  redirect("/teach?ok=profile");
}

export async function updateInstituteAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/manage");
  await supabase.from("institutes").update({ name: str(form, "name"), town: str(form, "town"), bio: str(form, "bio") }).eq("owner_id", user.id);
  revalidatePath("/manage");
  redirect("/manage?ok=profile");
}

// ---------- admin ----------
export async function adminVerifyAction(form: FormData) {
  const { supabase } = await client();
  const { error } = await supabase.rpc("admin_verify", {
    p_kind: str(form, "kind"),
    p_id: str(form, "id"),
    p_status: str(form, "status"),
  });
  revalidatePath("/admin");
  if (error) redirect(`/admin?error=${encodeURIComponent(error.message)}`);
}

// ---------- meeting / content link ----------
export async function saveLinkAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const id = str(form, "offering_id");
  const url = str(form, "url");
  const path = str(form, "path") || `/manage/course/${id}`;
  if (!url) {
    await supabase.from("offering_links").delete().eq("offering_id", id);
  } else {
    if (!/^https?:\/\//i.test(url)) redirect(`${path}?error=${encodeURIComponent("الرابط يجب أن يبدأ بـ https://")}`);
    const { error } = await supabase.from("offering_links").upsert({ offering_id: id, url, note: str(form, "note") || null, updated_at: new Date().toISOString() });
    if (error) redirect(`${path}?error=${encodeURIComponent(error.message)}`);
  }
  revalidatePath(path);
  redirect(`${path}?saved=link`);
}

// ---------- teacher availability ----------
export async function saveAvailabilityAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach");
  const { data: t } = await supabase.from("teachers").select("id").eq("user_id", user.id).maybeSingle();
  if (!t) redirect("/teach");
  const from = str(form, "from") || "15:00";
  const to = str(form, "to") || "21:00";
  if (to <= from) redirect(`/teach?error=${encodeURIComponent("ساعة النهاية يجب أن تكون بعد ساعة البداية.")}`);
  const days = form.getAll("days").map(Number).filter((d) => d >= 0 && d <= 6);
  await supabase.from("availability").delete().eq("teacher_id", t.id);
  if (days.length) await supabase.from("availability").insert(days.map((w) => ({ teacher_id: t.id, weekday: w, start_time: from, end_time: to })));
  revalidatePath("/teach");
  redirect("/teach?ok=hours");
}
