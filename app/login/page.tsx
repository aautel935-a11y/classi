import { LoginForm } from "./LoginForm";

export default async function Login({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  return (
    <div className="wrap">
      <div className="section">
        <LoginForm next={sp.next && sp.next.startsWith("/") ? sp.next : "/"} initial={sp.mode === "up" ? "up" : "in"} />
      </div>
    </div>
  );
}
