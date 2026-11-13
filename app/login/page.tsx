import { LoginForm } from "./LoginForm";
import { safePath } from "@/lib/safe";
import { ErrorNote } from "@/components/ErrorNote";

export default async function Login({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  return (
    <div className="wrap">
      <div className="section">
        <ErrorNote msg={sp.error} />
        {sp.signed_out === "all" && <p className="note" role="status">خرجت من حسابك على كل الأجهزة.</p>}
        <LoginForm next={safePath(sp.next, "/")} initial={sp.mode === "up" ? "up" : "in"} />
      </div>
    </div>
  );
}
