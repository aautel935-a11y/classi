import { Icon } from "@/components/Icon";
import { addChildAction, removeChildAction, signOutAction, switchRoleAction, updateProfileAction } from "@/app/actions";
import { requireUser } from "@/lib/session";
import { TOWNS, type Role } from "@/lib/types";
import { initials } from "@/lib/format";

export const dynamic = "force-dynamic";

const ROLES: [Role, string][] = [["guardian", "ولي أمر / طالب"], ["teacher", "معلم"], ["institute", "معهد"]];

export default async function Account() {
  const { supabase, user, profile } = await requireUser("/account");
  const { data: kids } = await supabase.from("children").select("id,name,grade").order("created_at");
  const active = profile?.active_role === "student" ? "guardian" : profile?.active_role ?? "guardian";
  return (
    <div className="wrap">
      <div className="section">
        <div className="row" style={{ gap: 12 }}>
          <div className="avatar lg">{initials(profile?.full_name || user.email || "؟")}</div>
          <div className="stack" style={{ gap: 2, minWidth: 0 }}>
            <h1 style={{ fontSize: 22 }}>{profile?.full_name || "حسابي"}</h1>
            <span className="muted small" dir="ltr" style={{ textAlign: "right" }}>{user.email}</span>
          </div>
        </div>

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
                <form action={removeChildAction}>
                  <input type="hidden" name="id" value={k.id} />
                  <button className="link small" style={{ color: "var(--bad)" }}>حذف</button>
                </form>
              </div>
            ))}
            <form action={addChildAction} className="card formstack">
              <div className="typeform">
                <label className="field" htmlFor="kid-name">الاسم<input id="kid-name" name="name" required /></label>
                <label className="field" htmlFor="kid-grade">الصف<input id="kid-grade" name="grade" placeholder="مثلاً: صف 10" /></label>
              </div>
              <button className="btn ghost"><Icon name="plus" />إضافة ابن أو ابنة</button>
            </form>
          </>
        )}

        <h2>بياناتي</h2>
        <form action={updateProfileAction} className="card formstack">
          <label className="field" htmlFor="full_name">الاسم<input id="full_name" name="full_name" defaultValue={profile?.full_name ?? ""} /></label>
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
      </div>
    </div>
  );
}
