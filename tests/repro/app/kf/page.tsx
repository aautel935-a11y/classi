import { kf } from "../actions";
import { KeepForm } from "./KeepForm";
export const dynamic = "force-dynamic";
// Same as the minimal page, plus Classi's KeepForm inside the form.
export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  return (<main><p id="state">ok={sp.ok ?? "none"}</p>
    <form id="kf-x" action={kf}><KeepForm formId="kf-x" /><input name="a" defaultValue="x" /><button>kf</button></form></main>);
}
