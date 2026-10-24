import { requireUser } from "@/lib/session";
import { NewPasswordForm } from "./NewPasswordForm";

export default async function NewPassword() {
  await requireUser("/account/password");
  return (
    <div className="wrap">
      <div className="section">
        <h1>كلمة مرور جديدة</h1>
        <NewPasswordForm />
      </div>
    </div>
  );
}
