import { initials } from "@/lib/format";

/** A person's or institute's photo, or their initials when there is none. */
export function Avatar({ name, url, size = "", inst = false }: { name: string; url?: string | null; size?: "" | "lg" | "sm"; inst?: boolean }) {
  const cls = `avatar ${size} ${inst ? "inst" : ""}`;
  if (url) return <img className={`${cls} photo`} src={url} alt={name} loading="lazy" />;
  return <div className={cls} aria-hidden="true">{initials(name)}</div>;
}
