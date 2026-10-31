import { NextResponse } from "next/server";
import { runHealthChecks } from "@/lib/health";

export const dynamic = "force-dynamic";

// Public status: 200 when everything works, 503 when a service fails, so an uptime monitor (for example
// UptimeRobot) can watch this address. It checks only Classi's own services (database, storage, sign-in);
// the paid third-party checks (Resend, 019) run in the authenticated daily cron and the admin page.
// Shared caches may reuse the answer for 60 seconds, so hammering this URL costs almost nothing.
export async function GET() {
  const result = await runHealthChecks({ external: false });
  return NextResponse.json(
    { ok: result.ok, checked_at: result.checked_at, checks: result.checks.map(({ name, status }) => ({ name, status })) },
    { status: result.ok ? 200 : 503, headers: { "Cache-Control": "public, s-maxage=60, stale-while-revalidate=30" } }
  );
}
