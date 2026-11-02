import type { Metadata, Viewport } from "next";
import Link from "next/link";
import "./globals.css";
import { BottomNav } from "@/components/BottomNav";
import { SupportButton } from "@/components/SupportButton";
import { Icon, Logo } from "@/components/Icon";
import { isConfigured } from "@/lib/supabase/server";
import { getSession, isBlocked } from "@/lib/session";
import { supportWhatsapp } from "@/lib/settings";
import { signOutAction } from "@/app/actions";
import { navFor } from "@/lib/types";
import { IS_STAGING, SITE } from "@/lib/site";
import { Splash, splashScript } from "@/components/Splash";
import localFont from "next/font/local";

// Fonts are self-hosted from app/fonts (subset to Arabic + Latin, licensed under the SIL OFL, see app/fonts/OFL-*.txt):
// no render-blocking stylesheet from fonts.googleapis.com, and no download from Google during the build (a failed
// fetch there used to fail builds). The text appears in the fallback font at once (display: swap).
const chalk = localFont({ src: "./fonts/aref-ruqaa-700.woff", weight: "700", display: "swap", variable: "--f-chalk", preload: false });
const text = localFont({
  src: [
    { path: "./fonts/ibm-plex-sans-arabic-400.woff", weight: "400" },
    { path: "./fonts/ibm-plex-sans-arabic-500.woff", weight: "500" },
    { path: "./fonts/ibm-plex-sans-arabic-600.woff", weight: "600" },
  ],
  display: "swap", variable: "--f-text",
});
const display = localFont({ src: "./fonts/readex-pro-500-700.woff", weight: "500 700", display: "swap", variable: "--f-display" });

export const metadata: Metadata = {
  metadataBase: new URL(SITE),
  ...(IS_STAGING ? { robots: { index: false, follow: false } } : {}),
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
export const viewport: Viewport = { width: "device-width", initialScale: 1, viewportFit: "cover", themeColor: [{ media: "(prefers-color-scheme: light)", color: "#FFFFFF" }, { media: "(prefers-color-scheme: dark)", color: "#12151F" }], colorScheme: "light dark" };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ar" dir="rtl" className={`${chalk.variable} ${text.variable} ${display.variable}`} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: splashScript }} />
      </head>
      <body>
        {IS_STAGING && <div className="staging-bar" role="note">نسخة تجريبية (Staging): بيانات وهمية فقط، ولا تُرسل رسائل حقيقية.</div>}
        <Splash />
        {isConfigured() ? <Shell>{children}</Shell> : <SetupNotice />}
      </body>
    </html>
  );
}

async function Shell({ children }: { children: React.ReactNode }) {
  const { supabase, user, profile } = await getSession();
  // PERF-01: the badge counts and the support number are fetched in parallel; the support number is the same for
  // everyone, so it comes from a shared 5-minute cache (refreshed at once when the admin changes it).
  const [counts, support] = await Promise.all([
    user ? supabase.rpc("my_header_counts") : Promise.resolve({ data: null }),
    supportWhatsapp(),
  ]);
  const row = (Array.isArray(counts.data) ? counts.data[0] : counts.data) as { notifications: number; messages: number } | null;
  const unread = row?.notifications ?? 0;
  const unreadMessages = row?.messages ?? 0;
  if (isBlocked(profile)) return <Blocked status={profile!.status} until={profile!.suspended_until} reason={profile!.status_reason} />;
  const kind = navFor(profile?.active_role ?? "guardian");
  return (
    <>
      <div className="app">
        <header className="top">
          <div className="wrap" style={{ display: "flex", alignItems: "center", gap: 10, paddingBlock: 10 }}>
            <Link href={kind === "teacher" ? "/teach" : kind === "institute" ? "/manage" : "/"} prefetch={false} className="brand">
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
