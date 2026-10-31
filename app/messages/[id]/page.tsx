import Link from "next/link";
import { notFound } from "next/navigation";
import { Avatar } from "@/components/Avatar";
import { Icon } from "@/components/Icon";
import { reportConversationAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { Thread } from "./Thread";
import { PAGE_SIZE } from "@/lib/messages";

export const dynamic = "force-dynamic";

export default async function Conversation({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { id } = await params;
  const sp = await searchParams;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const { supabase, user } = await requireUser(`/messages/${id}`);
  const { data: conv } = await supabase
    .from("conversations")
    .select("id,user_id,teacher:teachers(id,name,photo_url),institute:institutes(id,name,logo_url)")
    .eq("id", id)
    .maybeSingle();
  if (!conv) notFound();
  const { data: member } = await supabase.rpc("is_conversation_member", { p_conv: id });
  const c = conv as any;
  const iAmFamily = c.user_id === user.id;
  let otherName: string, otherPhoto: string | null, profileHref: string | null;
  if (iAmFamily) {
    otherName = c.teacher?.name ?? c.institute?.name ?? "";
    otherPhoto = c.teacher?.photo_url ?? c.institute?.logo_url ?? null;
    profileHref = c.teacher ? `/teacher/${c.teacher.id}` : c.institute ? `/institute/${c.institute.id}` : null;
  } else {
    const { data: list } = await supabase.rpc("my_conversations");
    const row = ((list ?? []) as any[]).find((r) => r.id === id);
    otherName = row?.other_name ?? "ولي أمر";
    otherPhoto = row?.other_photo ?? null;
    profileHref = null;
  }
  // Newest page first (BUG-03: the old ascending limit hid every message after the 300th).
  const { data: newest } = await supabase.from("messages").select("id,sender_id,body,created_at,read_at").eq("conversation_id", id)
    .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(PAGE_SIZE);
  const messages = ((newest ?? []) as any[]).slice().reverse();
  if (member) await supabase.rpc("mark_conversation_read", { p_conv: id });

  return (
    <div className="wrap chat-page">
      <div className="chat-head">
        <Link className="back" href="/messages" aria-label="رجوع"><Icon name="back" /></Link>
        <Avatar name={otherName} url={otherPhoto} inst={!!c.institute && iAmFamily} size="sm" />
        {profileHref ? <Link href={profileHref}><b>{otherName}</b></Link> : <b>{otherName}</b>}
        {member && (
          <details className="spacer report">
            <summary className="link small">إبلاغ</summary>
            <form action={reportConversationAction} className="card formstack">
              <input type="hidden" name="conversation_id" value={id} />
              <label className="field" htmlFor="reason">ما المشكلة؟<input id="reason" name="reason" placeholder="مثلاً: كلام غير لائق" /></label>
              <button className="btn sm badb">إرسال البلاغ للإدارة</button>
            </form>
          </details>
        )}
      </div>
      {sp.reported && <p className="okmsg">وصل البلاغ للإدارة. شكراً لك.</p>}
      {!member && <p className="note">تقرأ هذه المحادثة لأنها بُلّغ عنها. لا يمكنك الكتابة فيها.</p>}
      <Thread conversationId={id} me={user.id} initial={messages} hasOlder={(newest ?? []).length === PAGE_SIZE} canWrite={!!member} />
    </div>
  );
}
