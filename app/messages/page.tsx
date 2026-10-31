import Link from "next/link";
import { Avatar } from "@/components/Avatar";
import { Icon } from "@/components/Icon";
import { requireUser } from "@/lib/session";
import { dayLong, isoDay, time } from "@/lib/format";
import { ErrorNote } from "@/components/ErrorNote";

export const dynamic = "force-dynamic";

type Conv = { id: string; other_name: string; other_photo: string | null; other_kind: string; last_body: string | null; last_at: string; unread: number; i_am_owner: boolean };

export default async function Messages({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase } = await requireUser("/messages");
  const { data } = await supabase.rpc("my_conversations");
  const list = (data ?? []) as Conv[];
  const today = isoDay(new Date());
  return (
    <div className="wrap">
      <div className="section">
        <h1>الرسائل</h1>
        <ErrorNote msg={sp.error} />
        {list.length === 0 && (
          <div className="empty">
            لا محادثات بعد. افتح صفحة معلم أو معهد واضغط «راسل» لتسأل قبل الحجز.
          </div>
        )}
        {list.map((c) => (
          <Link key={c.id} href={`/messages/${c.id}`} className={`card thread ${c.unread ? "unread" : ""}`}>
            <Avatar name={c.other_name} url={c.other_photo} inst={c.other_kind === "institute"} />
            <div className="body">
              <div className="row between">
                <b>{c.other_name}</b>
                <span className="small muted num">{isoDay(c.last_at) === today ? time(c.last_at) : dayLong(c.last_at)}</span>
              </div>
              <div className="row between" style={{ gap: 8 }}>
                <p className="small muted">{c.last_body ?? "ابدأ المحادثة"}</p>
                {c.unread > 0 && <span className="count num">{c.unread}</span>}
              </div>
            </div>
          </Link>
        ))}
        <p className="note"><Icon name="shield" />المحادثات داخل Classi فقط. لا تشارك معلومات حساسة، ويمكنك الإبلاغ عن أي محادثة.</p>
      </div>
    </div>
  );
}
