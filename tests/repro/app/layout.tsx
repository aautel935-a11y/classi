import Link from "next/link";
// Like Classi's bottom bar: links to the pages themselves (prefetched while they are shown).
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (<html lang="ar" dir="rtl"><body>{children}
    <nav><Link href="/">home</Link> <Link href="/kf">kf</Link> <Link href="/sp">sp</Link> <Link href="/r">r</Link></nav></body></html>);
}
