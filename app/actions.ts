"use server";

import { revalidatePath, revalidateTag } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { fromLocal } from "@/lib/format";
import { WEEKDAYS, datesOn, nextDays } from "@/lib/dates";
import { cleanMobile } from "@/lib/contact";
import type { OfferingType, Place, Role } from "@/lib/types";

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
    if (error) return { error: error.message };
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
    if (error) return { error: error.message };
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
  if (error) return { error: error.message };
  revalidatePath("/schedule");
  return { ok: true };
}

export async function cancelBookingAction(form: FormData) {
  revalidateTag("catalog");
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
  // The phone is changed only through a verified SMS code (PhoneLink), never typed in here.
  await supabase.from("profiles").update({ full_name: str(form, "full_name"), town: str(form, "town") || null, sms_ok: form.get("sms_ok") === "on" }).eq("id", user.id);
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
  if (error) redirect(`/teach?error=${encodeURIComponent("تعذّر حفظ الملف: " + error.message)}`);
  revalidatePath("/teach");
  redirect("/teach");
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
    if (size >= 2 && size <= 50) out.package_size = size;
    if (price > 0) out.package_price = price;
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
      days.map((d, i) => ({ offering_id: o.id, seq: i + 1, starts_at: fromLocal(d, tm).toISOString(), minutes: Number(row.minutes) || 90 }))
    );
  }
  revalidatePath("/teach");
  redirect("/teach?ok=published");
}

export async function deleteOfferingAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const id = str(form, "id");
  const back = str(form, "path") || "/teach";
  const { count } = await supabase.from("bookings").select("id", { count: "exact", head: true }).eq("offering_id", id);
  if ((count ?? 0) > 0) redirect(`${back}?error=${encodeURIComponent("لا يمكن حذف عرض عليه حجوزات. أخفِه بدلاً من ذلك.")}`);
  const { error } = await supabase.from("offerings").delete().eq("id", id);
  revalidatePath(back);
  redirect(`${back}?${error ? `error=${encodeURIComponent(error.message)}` : "ok=deleted"}`);
}

export async function toggleOfferingAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = str(form, "path") || "/teach";
  const active = str(form, "active") === "1";
  const { error } = await supabase.from("offerings").update({ active }).eq("id", str(form, "id"));
  revalidatePath(back);
  redirect(`${back}?${error ? `error=${encodeURIComponent(error.message)}` : active ? "ok=shown" : "ok=hidden"}`);
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
  if (error || !inst) redirect(`/manage?error=${encodeURIComponent("تعذّر الحفظ: " + (error?.message ?? ""))}`);
  const rooms = Math.min(10, Math.max(1, num(form, "rooms") || 1));
  await supabase.from("rooms").insert(Array.from({ length: rooms }, (_, i) => ({ institute_id: inst.id, name: `قاعة ${i + 1}` })));
  revalidatePath("/manage");
  redirect("/manage");
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
  if (error || !o) redirect(`/manage/new-course?error=${encodeURIComponent(error?.message ?? "تعذّر الحفظ")}`);
  const days = datesOn(start, weekdays, count);
  await supabase.from("sessions").insert(
    days.map((d, i) => ({ offering_id: o.id, seq: i + 1, starts_at: fromLocal(d, tm).toISOString(), minutes: [45, 60, 90, 120, 150].includes(num(form, "minutes")) ? num(form, "minutes") : 90, room_id: room }))
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
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  let ok = false;
  try {
    const u = new URL(url);
    const host = new URL((process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").trim()).hostname;
    ok = u.protocol === "https:" && u.hostname === host && u.pathname.startsWith(`/storage/v1/object/public/avatars/${user.id}/`);
  } catch {
    ok = false;
  }
  if (!ok) return { error: "تعذّر حفظ الصورة: الرابط لا يطابق حسابك." };
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
  revalidateTag("catalog");
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
      intro_video_url: /^https:\/\/\S{6,290}$/.test(str(form, "intro_video")) ? str(form, "intro_video") : null,
    })
    .eq("user_id", user.id);
  if (str(form, "intro_video") && !/^https:\/\//.test(str(form, "intro_video"))) redirect(`/teach?error=${encodeURIComponent("رابط الفيديو يجب أن يبدأ بـ https://")}`);
  if (form.has("whatsapp")) {
    const wa = str(form, "whatsapp") ? cleanMobile(str(form, "whatsapp")) : null;
    if (str(form, "whatsapp") && !wa) redirect(`/teach?error=${encodeURIComponent("رقم الواتساب غير صحيح. اكتب رقم جوال مثل 050-1234567.")}#profile`);
    await supabase.from("teachers").update({ whatsapp: wa }).eq("user_id", user.id);
  }
  if (form.has("bit_phone")) {
    const { error: bitErr } = await supabase.rpc("set_bit_phone", { p_phone: str(form, "bit_phone"), p_institute: false });
    if (bitErr) redirect(`/teach?error=${encodeURIComponent(bitErr.message)}`);
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
  const rows: { teacher_id: string; weekday: number; start_time: string; end_time: string }[] = [];
  for (let w = 0; w <= 6; w++) {
    if (form.get(`on_${w}`) !== "on") continue;
    const ranges = [[str(form, `from_${w}`), str(form, `to_${w}`)], [str(form, `from2_${w}`), str(form, `to2_${w}`)]].filter(([a, b]) => a && b);
    for (const [a, b] of ranges) {
      if (b <= a) redirect(`/teach?error=${encodeURIComponent(`في يوم ${WEEKDAYS[w]}: ساعة النهاية يجب أن تكون بعد البداية.`)}#hours`);
    }
    if (ranges.length === 2 && ranges[1][0] < ranges[0][1] && ranges[0][0] < ranges[1][1]) {
      redirect(`/teach?error=${encodeURIComponent(`في يوم ${WEEKDAYS[w]}: الفترتان متداخلتان.`)}#hours`);
    }
    for (const [a, b] of ranges) rows.push({ teacher_id: t.id, weekday: w, start_time: a, end_time: b });
  }
  const buffer = [0, 5, 10, 15, 30].includes(num(form, "buffer")) ? num(form, "buffer") : 0;
  await supabase.from("teachers").update({ buffer_minutes: buffer }).eq("id", t.id);
  await supabase.from("availability").delete().eq("teacher_id", t.id);
  if (rows.length) await supabase.from("availability").insert(rows);
  const days = rows;
  // People waiting for this teacher's private lessons hear about the new hours.
  if (days.length) await supabase.rpc("waitlist_hours_opened");
  revalidatePath("/teach");
  redirect("/teach?ok=hours#hours");
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
  redirect(`${path}?${error ? `error=${encodeURIComponent(error.message)}` : "saved=offer"}`);
}

// ---------- messages ----------
export async function startConversationAction(form: FormData) {
  const { supabase, user } = await client();
  const back = str(form, "back") || "/";
  if (!user) redirect(`/login?next=${encodeURIComponent(back)}`);
  const { data, error } = await supabase.rpc("start_conversation", {
    p_teacher: str(form, "teacher_id") || null,
    p_institute: str(form, "institute_id") || null,
  });
  if (error || !data) redirect(`/messages?error=${encodeURIComponent(error?.message ?? "تعذّر فتح المحادثة")}`);
  redirect(`/messages/${data}`);
}

export async function startBookingConversationAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const { data, error } = await supabase.rpc("start_conversation_for_booking", { p_booking: str(form, "booking_id") });
  if (error || !data) redirect(`/messages?error=${encodeURIComponent(error?.message ?? "تعذّر فتح المحادثة")}`);
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
  const back = str(form, "back") || "/";
  if (!user) redirect(`/login?next=${encodeURIComponent(back)}`);
  const { error } = await supabase.from("reports").insert({
    target_type: str(form, "target_type"),
    target_id: str(form, "target_id"),
    reason: str(form, "reason") || "other",
    details: str(form, "details").slice(0, 1000) || null,
  });
  redirect(`${back}?${error ? `report_error=${encodeURIComponent(error.message)}` : "reported=1"}`);
}

export async function adminSetStatusAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = str(form, "back") || "/admin";
  const { error } = await supabase.rpc("admin_set_user_status", {
    p_user: str(form, "user_id"),
    p_status: str(form, "status"),
    p_days: str(form, "status") === "suspended" ? num(form, "days") || 7 : null,
    p_reason: str(form, "reason") || null,
  });
  revalidatePath(back);
  redirect(`${back}${back.includes("?") ? "&" : "?"}${error ? `error=${encodeURIComponent(error.message)}` : "done=status"}`);
}

export async function adminHideAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = str(form, "back") || "/admin";
  const { error } = await supabase.rpc("admin_hide", {
    p_kind: str(form, "kind"),
    p_id: str(form, "id"),
    p_hidden: str(form, "hidden") === "1",
    p_reason: str(form, "reason") || null,
  });
  revalidatePath(back);
  redirect(`${back}${back.includes("?") ? "&" : "?"}${error ? `error=${encodeURIComponent(error.message)}` : "done=hide"}`);
}

export async function adminCloseReportAction(form: FormData) {
  const { supabase } = await client();
  const { error } = await supabase.rpc("admin_close_report", {
    p_report: str(form, "id"),
    p_status: str(form, "status"),
    p_note: str(form, "note") || null,
  });
  revalidatePath("/admin");
  redirect(`/admin?tab=reports${error ? `&error=${encodeURIComponent(error.message)}` : "&done=report"}`);
}

export async function cancelSeriesAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const back = str(form, "back") || "/schedule";
  const { data, error } = await supabase.rpc("cancel_series", { p_series: str(form, "id") });
  revalidatePath(back);
  redirect(`${back}?${error ? `error=${encodeURIComponent(error.message)}` : `cancelled_series=${data}`}`);
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
  if (error) return { error: error.message };
  revalidatePath(`/offer/${input.offeringId}`);
  revalidatePath("/schedule");
  return { ok: true, count: Number(data) };
}

export async function leaveWaitlistAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = str(form, "back") || "/schedule";
  const { error } = await supabase.rpc("leave_waitlist", { p_id: str(form, "id") });
  revalidatePath(back);
  redirect(`${back}${back.includes("?") ? "&" : "?"}${error ? `error=${encodeURIComponent(error.message)}` : "left=1"}`);
}

export async function respondWaitlistAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = str(form, "back") || "/teach";
  const accept = str(form, "accept") === "1";
  const { data, error } = await supabase.rpc("respond_waitlist", { p_id: str(form, "id"), p_accept: accept, p_reply: str(form, "reply") || null });
  revalidateTag("catalog");
  revalidatePath(back);
  if (error) redirect(`${back}?error=${encodeURIComponent(error.message)}#waitlist`);
  if (data) redirect(`/messages/${data}`);
  redirect(`${back}?wl=${accept ? "accepted" : "declined"}#waitlist`);
}

// ---------- phone notifications & reminders ----------
export async function savePushSubscriptionAction(sub: { endpoint: string; p256dh: string; auth: string }): Promise<Result> {
  const { supabase, user } = await client();
  if (!user) return { error: "سجّل الدخول أولاً." };
  const { error } = await supabase.rpc("save_push_subscription", { p_endpoint: sub.endpoint, p_p256dh: sub.p256dh, p_auth: sub.auth });
  return error ? { error: error.message } : { ok: true };
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
  redirect("/notifications");
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
  if (error) redirect(calBack(form, { error: error.message }));
  redirect(calBack(form, { ok: Number(data) > 1 ? `blocked:${data}` : "blocked" }));
}

export async function teacherUnblockAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach/calendar");
  const { error } = await supabase.rpc("teacher_unblock", { p_block: str(form, "id"), p_all: str(form, "all") === "1" });
  revalidateTag("catalog");
  redirect(calBack(form, error ? { error: error.message } : { ok: "opened" }));
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
  if (error) redirect(calBack(form, { error: error.message }));
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
  if (error) redirect(calBack(form, { error: error.message }));
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
  redirect(calBack(form, error ? { error: error.message } : { ok: "cancelled" }));
}

// ---------- lesson packages ----------
export async function buyPackageAction(form: FormData) {
  const { supabase, user } = await client();
  const id = str(form, "offering_id");
  if (!user) redirect(`/login?next=/offer/${id}`);
  const who = str(form, "who");
  const { error } = await supabase.rpc("buy_package", { p_offering: id, p_child: who && who !== "self" ? who : null, p_pay: str(form, "pay") || "bit" });
  revalidatePath(`/offer/${id}`);
  redirect(`/offer/${id}?${error ? `package_error=${encodeURIComponent(error.message)}` : "package=1"}`);
}

export async function cancelPackageAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = str(form, "back") || "/teach";
  const { error } = await supabase.rpc("cancel_package", { p_package: str(form, "id") });
  revalidatePath(back);
  redirect(`${back}?${error ? `error=${encodeURIComponent(error.message)}` : "saved=package"}`);
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
  const back = str(form, "back") || "/teach";
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
  if (error) redirect(`/teach/report?booking=${booking}&error=${encodeURIComponent(error.message)}`);
  revalidatePath("/teach");
  redirect(`${back}${back.includes("?") ? "&" : "?"}ok=report`);
}

export async function writeSessionReportsAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login?next=/teach");
  const session = str(form, "session_id");
  const back = str(form, "back") || "/teach";
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
  if (error) redirect(`/teach/report?session=${session}&error=${encodeURIComponent(error.message)}`);
  revalidatePath("/teach");
  redirect(`${back}${back.includes("?") ? "&" : "?"}ok=report`);
}

// ---------- payments (cash / Bit, no gateway) ----------
function backTo(form: FormData, fallback: string) {
  const b = str(form, "back");
  return b.startsWith("/") ? b : fallback;
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
  redirect(withQ(back, error ? `error=${encodeURIComponent(error.message)}` : "paid_reported=1"));
}

export async function confirmPaymentAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/teach#payments");
  const { error } = await supabase.rpc("confirm_payment", {
    p_booking: str(form, "booking_id") || null, p_package: str(form, "package_id") || null, p_received: str(form, "received") !== "0",
  });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(error.message)}` : "ok=payment"));
}

// ---------- admin content review ----------
export async function adminReviewAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const { error } = await supabase.rpc("admin_review", {
    p_kind: str(form, "kind"), p_id: str(form, "id"), p_approve: str(form, "approve") === "1", p_note: str(form, "note") || null,
  });
  revalidatePath("/admin");
  redirect(`/admin?tab=review&${error ? `error=${encodeURIComponent(error.message)}` : "done=1"}`);
}

// ---------- subscriptions (teachers & institutes pay the platform) ----------
export async function requestSubscriptionAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/teach#subscription");
  const { error } = await supabase.rpc("request_subscription", { p_plan: str(form, "plan") });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(error.message)}` : "sub=chosen"));
}

export async function reportSubscriptionAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/teach#subscription");
  const { error } = await supabase.rpc("report_subscription_payment", { p_id: str(form, "id") });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(error.message)}` : "sub=reported"));
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
  } else if (op === "plan") {
    ({ error } = await supabase.rpc("admin_set_plan", { p_code: str(form, "code"), p_price: num(form, "price"), p_active: form.get("active") === "on" }));
  } else if (op === "demo") {
    ({ error } = await supabase.rpc("admin_demo_visible", { p_visible: str(form, "visible") === "1" }));
  }
  revalidatePath("/admin");
  revalidatePath("/");
  redirect(`/admin?tab=subs&${error ? `error=${encodeURIComponent(error.message)}` : "done=1"}`);
}

// ---------- ratings ----------
export async function leaveReviewAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  const booking = str(form, "booking_id");
  if (!user) redirect(`/login?next=/review?booking=${booking}`);
  const { error } = await supabase.rpc("leave_review", { p_booking: booking, p_stars: num(form, "stars"), p_body: str(form, "body") || null });
  if (error) redirect(`/review?booking=${booking}&error=${encodeURIComponent(error.message)}`);
  redirect(`/review?booking=${booking}&done=1`);
}

export async function replyReviewAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/teach#reviews");
  const { error } = await supabase.rpc("reply_review", { p_review: str(form, "id"), p_reply: str(form, "reply") });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(error.message)}` : "ok=reply"));
}

export async function adminHideReviewAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase } = await client();
  const { error } = await supabase.rpc("admin_hide_review", { p_review: str(form, "id"), p_hidden: str(form, "hidden") === "1" });
  const back = backTo(form, "/admin");
  redirect(withQ(back, error ? `error=${encodeURIComponent(error.message)}` : "done=1"));
}

// ---------- delete my account ----------
export async function deleteAccountAction(form: FormData) {
  revalidateTag("catalog");
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const { error } = await supabase.rpc("delete_my_account", { p_confirm: str(form, "confirm") });
  if (error) redirect(`/account?error=${encodeURIComponent(error.message)}#delete`);
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
  redirect(withQ(back, error ? `error=${encodeURIComponent(error.message)}` : "ok=cancelled"));
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
  if (error) redirect(withQ(back, `enroll=1&error=${encodeURIComponent(error.message)}`));
  const { data: b } = await supabase.from("bookings").select("booked_by").eq("id", data as string).maybeSingle();
  redirect(withQ(back, `ok=enrolled&linked=${b?.booked_by ? "1" : "0"}`));
}

export async function linkWalkInAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const back = backTo(form, "/manage");
  const { error } = await supabase.rpc("institute_link_booking", { p_booking: str(form, "booking_id") });
  revalidatePath(back.split(/[?#]/)[0]);
  redirect(withQ(back, error ? `error=${encodeURIComponent(error.message)}` : "ok=linked"));
}

export async function removeStaffAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const { error } = await supabase.rpc("institute_remove_staff", { p_teacher: str(form, "teacher_id") });
  revalidatePath("/manage");
  redirect(`/manage?${error ? `error=${encodeURIComponent(error.message)}` : "saved=staff_removed"}#staff`);
}

export async function teacherVacationAction(form: FormData) {
  const { supabase, user } = await client();
  if (!user) redirect("/login");
  const from = str(form, "from");
  const to = str(form, "to") || from;
  const { data, error } = await supabase.rpc("teacher_vacation", { p_from: from, p_to: to, p_note: str(form, "note") || null });
  revalidatePath("/teach/calendar");
  redirect(`/teach/calendar?day=${from}&${error ? `error=${encodeURIComponent(error.message)}` : `ok=vacation&n=${data ?? 0}`}`);
}
