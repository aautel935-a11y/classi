import { same, hash, other } from "./actions";
export const dynamic = "force-dynamic";
export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  return (
    <main>
      <p id="state">ok={sp.ok ?? "none"}</p>
      <form action={same}><button>same</button></form>
      <form action={hash}><button>hash</button></form>
      <form action={other}><button>other</button></form>
      <section id="part" style={{ marginTop: 1200 }}>part</section>
    </main>
  );
}
