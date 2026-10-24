import { NextResponse } from "next/server";
import { runHealthChecks } from "@/lib/health";

export const dynamic = "force-dynamic";

// Public status: 200 when everything works, 503 when a service fails, so an
// uptime monitor (for example UptimeRobot) can watch this address.
export async function GET() {
  const result = await runHealthChecks();
  return NextResponse.json(
    { ok: result.ok, checked_at: result.checked_at, checks: result.checks.map(({ name, status, ms }) => ({ name, status, ms })) },
    { status: result.ok ? 200 : 503, headers: { "Cache-Control": "no-store" } }
  );
}
