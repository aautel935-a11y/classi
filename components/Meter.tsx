import { LEVELS } from "@/lib/types";

export type ReportRow = {
  id: string; offering_id: string; title: string; teacher: string | null; child_id: string | null; child_name: string | null; lesson_at: string;
  present: boolean; summary: string | null; homework: string | null; understanding: number | null; participation: number | null; note: string | null; read_at: string | null;
};

export function Meter({ value }: { value: number | null }) {
  if (!value) return null;
  return (
    <span className="meter" aria-label={LEVELS[value]}>
      {[1, 2, 3, 4, 5].map((n) => <i key={n} className={n <= value ? "on" : ""} />)}
    </span>
  );
}

