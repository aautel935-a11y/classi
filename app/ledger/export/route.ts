import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { chargesCsv, type ChargeRow } from "@/lib/ledger";

export const dynamic = "force-dynamic";

// CSV of the business's charges for its accountant. Owner, or staff holding payments.reports. The database functions
// decide what the caller may see; the business comes from ?b=t:<id> or ?b=i:<id> and is checked again there.
export async function GET(request: NextRequest) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const b = request.nextUrl.searchParams.get("b") ?? "";
  const m = /^([ti]):([0-9a-f-]{36})$/i.exec(b);
  const { data: list } = await supabase.rpc("my_ledger_businesses");
  const biz = ((list ?? []) as { kind: string; business_id: string; is_owner: boolean; can_reports: boolean }[])
    .find((x) => (m ? x.kind[0] === m[1] && x.business_id === m[2] : true));
  if (!biz || !(biz.is_owner || biz.can_reports)) return NextResponse.json({ error: "forbidden" }, { status: 403 });
  const { data, error } = await supabase.rpc("business_charges", {
    p_teacher: biz.kind === "teacher" ? biz.business_id : null, p_institute: biz.kind === "institute" ? biz.business_id : null, p_status: null,
  });
  if (error) return NextResponse.json({ error: "unavailable" }, { status: 503 });
  const day = new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Jerusalem" });
  return new NextResponse(chargesCsv((data ?? []) as ChargeRow[]), {
    headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": `attachment; filename="classi-ledger-${day}.csv"`,
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}
