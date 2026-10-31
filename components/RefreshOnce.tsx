"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

/** Re-render the server parts of the page once after it opens (e.g. so the header badge drops read items). */
export function RefreshOnce() {
  const router = useRouter();
  useEffect(() => { router.refresh(); }, [router]);
  return null;
}
