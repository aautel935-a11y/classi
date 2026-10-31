export const dynamic = "force-dynamic";
export default async function R({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  return <p id="state">r ok={sp.ok ?? "none"}</p>;
}
