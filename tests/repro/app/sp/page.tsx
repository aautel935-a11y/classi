import { sp as act } from "../actions";
import { Probe } from "./Probe";
export const dynamic = "force-dynamic";
// Only useSearchParams in a client component.
export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  return (<main><p id="state">ok={sp.ok ?? "none"}</p><Probe /><form action={act}><button>sp</button></form></main>);
}
