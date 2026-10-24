import { startConversationAction } from "@/app/actions";
import { Icon } from "./Icon";

/** "Message" button on a teacher's or institute's page. */
export function MessageButton({ teacherId, instituteId, back, label }: { teacherId?: string; instituteId?: string; back: string; label: string }) {
  return (
    <form action={startConversationAction}>
      {teacherId && <input type="hidden" name="teacher_id" value={teacherId} />}
      {instituteId && <input type="hidden" name="institute_id" value={instituteId} />}
      <input type="hidden" name="back" value={back} />
      <button className="btn ghost block"><Icon name="chat" />{label}</button>
    </form>
  );
}
