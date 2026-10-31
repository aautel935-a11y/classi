import { NextResponse, type NextRequest } from "next/server";
// Same shape as Classi's middleware when REPRO_MW=1 (passes the request through and sets a cookie).
export function middleware(request: NextRequest) {
  const response = NextResponse.next({ request });
  if (process.env.REPRO_MW === "1") response.cookies.set("probe", String(Date.now()), { path: "/" });
  return response;
}
