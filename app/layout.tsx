import type { Metadata, Viewport } from "next";
import Link from "next/link";
import "./globals.css";
import { BottomNav } from "@/components/BottomNav";
import { SupportButton } from "@/components/SupportButton";
import { Icon, Logo } from "@/components/Icon";
import { isConfigured } from "@/lib/supabase/server";
import { getSession, isBlocked } from "@/lib/session";
import { signOutAction } from "@/app/actions";
import { navFor } from "@/lib/types";
import { SITE } from "@/lib/site";
import { Splash, splashScript } from "@/components/Splash";

export const metadata: Metadata = {
  metadataBase: new URL(SITE),
  title: { default: "Classi · كل التعليم في مكان واحد", template: "%s · Classi" },
  description: "معلمون خصوصيون، مجموعات تقوية، دورات معاهد وتعليم أونلاين في مكان واحد.",
  openGraph: {
    type: "website", siteName: "Classi", locale: "ar_IL", url: SITE,
    title: "Classi · كل التعليم في مكان واحد",
    description: "احجز معلماً خصوصياً أو مجموعة تقوية أو دورة معهد في بلدك أو أونلاين.",
    images: [{ url: "/og.png", width: 1200, height: 630, alt: "Classi" }],
  },
  twitter: { card: "summary_large_image", images: ["/og.png"] },
  appleWebApp: { capable: true, title: "Classi", statusBarStyle: "default" },
  icons: { apple: "/apple-touch-icon.png" },
};
export const viewport: Viewport = { width: "device-width", initialScale: 1, viewportFit: "cover", themeColor: "#FFFFFF", colorScheme: "light" };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ar" dir="rtl" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: splashScript }} />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Aref+Ruqaa:wght@700&family=IBM+Plex+Sans+Arabic:wght@400;500;600&family=Readex+Pro:wght@500;600;700&display=swap"
        />
      </head>
      <body>
        <Splash />
        {isConfigured() ? <Shell>{children}</Shell> : <SetupNotice />}
      </body>
    </html>
  );
}

async function Shell({ children }: { children: React.ReactNode }) {
  const { supabase, user, profile } = await getSession();
  let unread = 0;
  let unreadMessages = 0;
  if (user) {
    const { data } = await supabase.rpc("my_header_counts");
    const row = (Array.isArray(data) ? data[0] : data) as { notifications: number; messages: number } | null;
    unread = row?.notifications ?? 0;
    unreadMessages = row?.messages ?? 0;
  }
  const { data: support } = await supabase.rpc("setting", { p_key: "support_whatsapp" });
  if (isBlocked(profile)) return <Blocked status={profile!.status} until={profile!.suspended_until} reason={profile!.status_reason} />;
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
            {user && (
              <Link href="/notifications" className="hdr-bell" aria-label={unread ? `الإشعارات، ${unread} جديدة` : "الإشعارات"}>
                <Icon name="bell" />
                {unread > 0 && <i className="num">{unread}</i>}
              </Link>
            )}
            {!user && (
              <Link className="btn sm" href="/login">
                تسجيل الدخول
              </Link>
            )}
          </div>
        </header>
        <main>{children}</main>
      </div>
      <BottomNav kind={kind} unread={unreadMessages} />
      <SupportButton phone={(support as string | null) || null} />
    </>
  );
}

function Blocked({ status, until, reason }: { status: string; until: string | null; reason: string | null }) {
  return (
    <div className="setup" dir="rtl">
      <h1>{status === "banned" ? "تم إيقاف هذا الحساب" : "حسابك موقوف مؤقتاً"}</h1>
      {status !== "banned" && until && <p>ينتهي الإيقاف في {new Date(until).toLocaleDateString("ar-u-nu-latn", { timeZone: "Asia/Jerusalem", day: "numeric", month: "long", year: "numeric" })}.</p>}
      {reason && <p className="muted">السبب: {reason}</p>}
      <p className="small muted">إذا كنت تعتقد أن هذا خطأ، راسل إدارة Classi.</p>
      <form action={signOutAction}><button className="btn ghost">تسجيل الخروج</button></form>
    </div>
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
