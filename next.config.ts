import type { NextConfig } from "next";

// Security headers on every response (audit SEC-12).
// The enforced CSP only covers framing, plugins, <base> and form targets, which cannot break the app; a full
// script/style policy runs in report-only mode first so violations show up in the browser console before it
// is enforced (Next.js inline scripts need a nonce for that step).
const supabase = "https://*.supabase.co wss://*.supabase.co";
const securityHeaders = [
  { key: "Content-Security-Policy", value: "frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'" },
  {
    key: "Content-Security-Policy-Report-Only",
    value: [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline' https://challenges.cloudflare.com",
      "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
      "font-src 'self' https://fonts.gstatic.com",
      `img-src 'self' data: blob: https://*.supabase.co https://i.ytimg.com`,
      `connect-src 'self' ${supabase}`,
      "frame-src https://www.youtube-nocookie.com https://challenges.cloudflare.com",
      "worker-src 'self'",
      "manifest-src 'self'",
    ].join("; "),
  },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=()" },
  { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains" },
];

const nextConfig: NextConfig = {
  poweredByHeader: false,
  // Type and lint errors fail the build (SEC-35); CI runs tsc, next lint and next build on every push.
  async headers() {
    return [{ source: "/(.*)", headers: securityHeaders }];
  },
};

export default nextConfig;
