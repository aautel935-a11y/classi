import { unstable_cache } from "next/cache";
import { publicClient } from "./supabase/public";

/** The support WhatsApp number (admin setting), shared by every visitor and cached for 5 minutes (tag "settings"). */
export const supportWhatsapp = unstable_cache(
  async () => {
    const { data } = await publicClient().rpc("setting", { p_key: "support_whatsapp" });
    return (data as string | null) ?? null;
  },
  ["support-whatsapp-v1"],
  { revalidate: 300, tags: ["settings"] }
);
