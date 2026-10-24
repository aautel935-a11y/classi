import { createClient } from "@supabase/supabase-js";

/** Client without the visitor's session, for public catalogue data that can be cached and shared. */
export const publicClient = () =>
  createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
