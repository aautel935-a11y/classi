import { requireUser } from "@/lib/session";
import { NewOfferForm } from "./NewOfferForm";

export const dynamic = "force-dynamic";

export default async function NewOffer({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase } = await requireUser("/teach/new");
  const [{ data: subjects }, { data: levels }] = await Promise.all([
    supabase.from("subjects").select("id,name").order("id"),
    supabase.from("levels").select("id,name").order("sort"),
  ]);
  return (
    <div className="wrap">
      <NewOfferForm subjects={subjects ?? []} levels={levels ?? []} error={sp.error} />
    </div>
  );
}
