import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { SITE } from "@/lib/site";
import { icsFile } from "@/lib/contact";

export const dynamic = "force-dynamic";


// A booking (or a whole course / weekly series) as a calendar file. Only the person who booked can open it.
export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) return new NextResponse("not found", { status: 404 });
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.redirect(new URL(`/login?next=/schedule`, SITE));
  const { data: b } = await supabase
    .from("bookings")
    .select("id,series_id,starts_at,minutes,mode,offering:offerings(id,type,title,minutes,teacher:teachers!offerings_teacher_id_fkey(name),institute:institutes(name)),session:sessions!bookings_session_id_fkey(starts_at,minutes)")
    .eq("id", id).eq("booked_by", user.id).in("status", ["pending", "confirmed"]).maybeSingle();
  if (!b) return new NextResponse("not found", { status: 404 });
  const o = (b as any).offering;
  const who = o.teacher ? `أ. ${o.teacher.name}` : o.institute?.name ?? "";
  const title = `${o.title} · ${who}`;
  const details = `حجز عبر Classi\n${SITE}/schedule`;
  const where = (b as any).mode === "online" ? "أونلاين" : undefined;
  let events: { uid: string; title: string; start: string; minutes: number; details: string; location?: string }[] = [];
  const now = new Date().toISOString();
  if (o.type === "course") {
    const { data: ss } = await supabase.from("sessions").select("id,starts_at,minutes").eq("offering_id", o.id).eq("cancelled", false).gt("starts_at", now).order("starts_at");
    events = (ss ?? []).map((s) => ({ uid: s.id, title, start: s.starts_at, minutes: s.minutes || o.minutes, details, location: where }));
  } else if ((b as any).series_id) {
    const { data: bs } = await supabase.from("bookings").select("id,starts_at,minutes").eq("series_id", (b as any).series_id).eq("booked_by", user.id).in("status", ["pending", "confirmed"]).gt("starts_at", now).order("starts_at");
    events = (bs ?? []).filter((x) => x.starts_at).map((x) => ({ uid: x.id, title, start: x.starts_at!, minutes: x.minutes || o.minutes, details, location: where }));
  } else {
    const start = (b as any).starts_at ?? (b as any).session?.starts_at;
    if (start) events = [{ uid: b.id, title, start, minutes: (b as any).minutes || (b as any).session?.minutes || o.minutes, details, location: where }];
  }
  if (!events.length) return new NextResponse("no upcoming dates", { status: 404 });
  return new NextResponse(icsFile(events), {
    headers: { "Content-Type": "text/calendar; charset=utf-8", "Content-Disposition": `attachment; filename="classi-${b.id.slice(0, 8)}.ics"` },
  });
}
