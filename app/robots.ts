import { IS_STAGING, SITE } from "@/lib/site";
import type { MetadataRoute } from "next";

export default function robots(): MetadataRoute.Robots {
  if (IS_STAGING) return { rules: [{ userAgent: "*", disallow: "/" }] };
  return {
    rules: [{ userAgent: "*", allow: ["/", "/search", "/offer/", "/teacher/", "/institute/", "/terms", "/privacy"], disallow: ["/admin", "/teach", "/manage", "/account", "/messages", "/schedule", "/notifications", "/reports", "/api/"] }],
    sitemap: `${SITE}/sitemap.xml`,
  };
}
