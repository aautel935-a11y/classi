import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "./supabase/server";
import type { Role } from "./types";

export type Profile = { id: string; full_name: string; town: string | null; roles: Role[]; active_role: Role };

/** Current user and profile, once per request. */
export const getSession = cache(async () => {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { supabase, user: null, profile: null as Profile | null };
  const { data: profile } = await supabase.from("profiles").select("id,full_name,town,roles,active_role").eq("id", user.id).maybeSingle();
  return { supabase, user, profile: profile as Profile | null };
});

export async function requireUser(next: string) {
  const s = await getSession();
  if (!s.user) redirect(`/login?next=${encodeURIComponent(next)}`);
  return s as typeof s & { user: NonNullable<typeof s.user>; profile: Profile };
}
