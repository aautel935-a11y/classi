import { NextResponse, type NextRequest } from "next/server";
import { workerClient } from "@/lib/supabase/worker";

export const dynamic = "force-dynamic";

// D-08: proves the server-only path end to end WITHOUT delivering anything. With the right dispatch secret it calls
// worker_wake_ok through the service-role key, which records app_secrets.d08_worker_seen_at (the guard of step B).
// It never claims, sends, logs or drops anything: no notification, sign-in code or SMS quota is touched, whatever the
// environment's push, email or SMS settings are. There is no fallback to the old public functions: without the server
// key it answers 503. tests/check-worker-key.mjs keeps this file free of any claim or delivery call.
export async function POST(request: NextRequest) {
  let secret = "";
  try {
    secret = String((await request.json())?.secret ?? "");
  } catch {}
  if (!secret) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const w = workerClient();
  if (!w) return NextResponse.json({ error: "server key not configured" }, { status: 503 });
  const { data, error } = await w.rpc("worker_wake_ok", { p_secret: secret });
  if (error) return NextResponse.json({ error: "worker functions unavailable" }, { status: 503 });
  if (data !== true) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  return NextResponse.json({ ok: true, probe: true, delivered: 0 });
}
