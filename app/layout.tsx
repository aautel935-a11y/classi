import type { Metadata, Viewport } from "next";
import Link from "next/link";
import "./globals.css";
import { BottomNav } from "@/components/BottomNav";
import { Logo } from "@/components/Icon";
import { isConfigured } from "@/lib/supabase/server";
import { getSession } from "@/lib/session";
import { navFor } from "@/lib/types";

export const metadata: Metadata = {
  title: "Classi",
  description: "معلمون خصوصيون، مجموعات تقوية، دورات معاهد وتعليم أونلاين في مكان واحد.",
  appleWebApp: { capable: true, title: "Classi", statusBarStyle: "default" },
};
export const viewport: Viewport = { width: "device-width", initialScale: 1, viewportFit: "cover", themeColor: "#FFFFFF", colorScheme: "light" };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ar" dir="rtl">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Aref+Ruqaa:wght@700&family=IBM+Plex+Sans+Arabic:wght@400;500;600&family=Readex+Pro:wght@500;600;700&display=swap"
        />
      </head>
      <body>{isConfigured() ? <Shell>{children}</Shell> : <SetupNotice />}</body>
    </html>
  );
}

async function Shell({ children }: { children: React.ReactNode }) {
  const { supabase, user, profile } = await getSession();
  let unread = 0;
  if (user) {
    const { count } = await supabase.from("notifications").select("id", { count: "exact", head: true }).is("read_at", null);
    unread = count ?? 0;
  }
  const kind = navFor(profile?.active_role ?? "guardian");
  return (
    <>
      <div className="app">
        <header className="top">
          <div className="wrap" style={{ display: "flex", alignItems: "center", gap: 10, paddingBlock: 10 }}>
            <Link href={kind === "teacher" ? "/teach" : kind === "institute" ? "/manage" : "/"} className="brand">
              <Logo />
              <span>Classi</span>
            </Link>
            <span className="spacer" />
            {!user && (
              <Link className="btn sm" href="/login">
                تسجيل الدخول
              </Link>
            )}
          </div>
        </header>
        <main>{children}</main>
      </div>
      <BottomNav kind={kind} unread={unread} />
    </>
  );
}

function SetupNotice() {
  return (
    <div className="setup" dir="rtl">
      <h1>Classi جاهز للربط</h1>
      <p>لم تُضبط بعد مفاتيح Supabase. أضف هذين المتغيّرين في إعدادات المشروع على Vercel ثم أعد النشر:</p>
      <p>
        <code>NEXT_PUBLIC_SUPABASE_URL</code>
      </p>
      <p>
        <code>NEXT_PUBLIC_SUPABASE_ANON_KEY</code>
      </p>
      <p className="muted small">تجدهما في Supabase تحت Project Settings ثم API.</p>
    </div>
  );
}
