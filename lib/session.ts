import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "./supabase/server";
import type { Role } from "./types";

export type Profile = {
  id: string; full_name: string; town: string | null; roles: Role[]; active_role: Role; avatar_url: string | null;
  status: "active" | "suspended" | "banned"; suspended_until: string | null; status_reason: string | null;
};

/** Suspended (until a date) or banned accounts can't use the app. */
export const isBlocked = (p: Profile | null) =>
  !!p && (p.status === "banned" || (p.status === "suspended" && (!p.suspended_until || new Date(p.suspended_until) > new Date())));

/** Current user and profile, once per request. */
export const getSession = cache(async () => {
  const supabase = await createClient();
  // Ask for the user and their own profile at the same time (row security returns only their row).
  const [{ data: { user } }, { data: profile }] = await Promise.all([
    supabase.auth.getUser(),
    supabase.from("profiles").select("id,full_name,town,roles,active_role,avatar_url,status,suspended_until,status_reason").maybeSingle(),
  ]);
  if (!user) return { supabase, user: null, profile: null as Profile | null };
  return { supabase, user, profile: profile as Profile | null };
});

export async function requireUser(next: string) {
  const s = await getSession();
  if (!s.user) redirect(`/login?next=${encodeURIComponent(next)}`);
  return s as typeof s & { user: NonNullable<typeof s.user>; profile: Profile };
}
