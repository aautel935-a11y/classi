import { Icon } from "@/components/Icon";
import { addChildAction, deleteAccountAction, removeChildAction, signOutAction, switchRoleAction, updateProfileAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { TOWNS, type Role } from "@/lib/types";
import { PhotoUpload } from "@/components/PhotoUpload";
import { PhoneLink } from "@/components/PhoneLink";
import Link from "next/link";
import { ErrorNote } from "@/components/ErrorNote";
import { safePath } from "@/lib/safe";
import { KeepForm } from "@/components/KeepForm";

export const dynamic = "force-dynamic";

const ROLES: [Role, string][] = [["guardian", "ولي أمر / طالب"], ["teacher", "معلم"], ["institute", "معهد"]];

export default async function Account({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { supabase, user, profile } = await requireUser("/account");
  const [{ data: kids }, { data: me }] = await Promise.all([
    supabase.from("children").select("id,name,grade").order("created_at"),
    supabase.from("profiles").select("phone,sms_ok").eq("id", user.id).maybeSingle(),
  ]);
  const smsOk = me?.sms_ok !== false;
  const active = profile?.active_role === "student" ? "guardian" : profile?.active_role ?? "guardian";
  return (
    <div className="wrap">
      <div className="section">
        <h1 style={{ fontSize: 22 }}>{profile?.full_name || "حسابي"}</h1>
        <span className="muted small num" dir="ltr" style={{ textAlign: "right" }}>{user.email || (user.phone ? `0${String(user.phone).replace(/^\+?972/, "")}` : "")}</span>
        <PhotoUpload kind="profile" name={profile?.full_name || user.email || "؟"} current={profile?.avatar_url ?? null} />
        {profile?.roles?.includes("admin") && <Link className="btn ghost block" href="/admin">لوحة الإدارة: توثيق المعلمين والمعاهد</Link>}

        <h2>الواجهة</h2>
        <div className="seg">
          {ROLES.map(([k, l]) => (
            <form key={k} action={switchRoleAction} style={{ display: "contents" }}>
              <input type="hidden" name="role" value={k} />
              <button aria-pressed={active === k}>{l}</button>
            </form>
          ))}
        </div>
        <p className="small muted">حساب واحد يمكن أن يكون ولي أمر ومعلماً في الوقت نفسه.</p>

        {active === "guardian" && (
          <>
            <h2 id="children">أبنائي</h2>
            {(kids ?? []).map((k) => (
              <div key={k.id} className="card" style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
                <div className="avatar">{k.name[0]}</div>
                <div style={{ flex: 1 }}>
                  <b>{k.name}</b>
                  {k.grade && <p className="small muted">{k.grade}</p>}
                </div>
                <details>
                  <summary className="link small" style={{ color: "var(--bad)" }}>حذف</summary>
                  <form action={removeChildAction} style={{ marginTop: 6 }}>
                    <input type="hidden" name="id" value={k.id} />
                    <button className="btn sm badb">تأكيد حذف {k.name}</button>
                  </form>
                </details>
              </div>
            ))}
            {sp.ok === "child_removed" && <p className="okmsg">حُذف الاسم من حسابك.</p>}
            <form action={addChildAction} className="card formstack">
              {sp.back && <input type="hidden" name="back" value={safePath(sp.back, "/account")} />}
              <div className="typeform">
                <label className="field" htmlFor="kid-name">الاسم<input id="kid-name" name="name" required /></label>
                <label className="field" htmlFor="kid-grade">الصف<input id="kid-grade" name="grade" placeholder="مثلاً: صف 10" /></label>
              </div>
              <button className="btn ghost"><Icon name="plus" />{sp.back ? "إضافة والعودة إلى الحجز" : "إضافة ابن أو ابنة"}</button>
            </form>
          </>
        )}

        <h2>بياناتي</h2>
        <ErrorNote msg={sp.error} />
        <PhoneLink loginPhone={user.phone ? `+${String(user.phone).replace(/^\+/, "")}` : null} profilePhone={me?.phone ?? null} />
        <form id="kf-updateProfile" action={updateProfileAction} className="card formstack">
            <KeepForm formId="kf-updateProfile" />
          <label className="field" htmlFor="full_name">الاسم<input id="full_name" name="full_name" defaultValue={profile?.full_name ?? ""} /></label>
          <label className="row small"><input type="checkbox" name="sms_ok" defaultChecked={smsOk} /> أوافق على استلام تذكيرات الحصص برسالة SMS أو واتساب</label>
          <label className="field" htmlFor="town">
            البلد
            <select id="town" name="town" defaultValue={profile?.town ?? ""}>
              <option value="">—</option>
              {TOWNS.map((t) => <option key={t}>{t}</option>)}
            </select>
          </label>
          <button className="btn ghost">حفظ</button>
        </form>

        <form action={signOutAction}>
          <button className="btn ghost block"><Icon name="logout" />تسجيل الخروج</button>
        </form>
        <details className="card" id="delete">
          <summary className="link small" style={{ color: "var(--bad)" }}>حذف حسابي نهائياً</summary>
          <form action={deleteAccountAction} className="formstack" style={{ marginTop: 10 }}>
            <p className="small">يُحذف حسابك وبياناتك وبيانات أبنائك، وتُلغى حصصك القادمة ويُبلَّغ المعلمون. إذا كنت معلماً أو معهداً، تختفي عروضك ويُبلَّغ طلابك. لا يمكن التراجع.</p>
            <label className="field">اكتب كلمة «احذف» للتأكيد<input name="confirm" required autoComplete="off" /></label>
            <button className="btn sm badb">حذف الحساب</button>
          </form>
        </details>
        <p className="small muted" style={{ textAlign: "center" }}>
          <Link className="link" href="/terms">شروط الاستخدام</Link> · <Link className="link" href="/privacy">سياسة الخصوصية</Link>
        </p>
      </div>
    </div>
  );
}
