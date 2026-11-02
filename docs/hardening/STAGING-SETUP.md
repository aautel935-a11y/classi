# تجهيز Staging (classi-staging)

**المبدأ:** Staging منفصل تماماً عن الإنتاج.
- مشروع Supabase مستقل، ومشروع Vercel مستقل.
- بيانات وهمية فقط.
- لا رسائل SMS حقيقية.
- غير مفهرس، ومحمي من الوصول العام.

**لا تُرسل أي كلمة مرور أو مفتاح في المحادثة.** القيم تُوضع مباشرة في لوحة الخدمة.

## الحالة

| البند | الحالة |
|---|---|
| مشروع Supabase `classi-staging` (`nfipmylyahhogykikuqo`، فرانكفورت، Micro) | ✅ أنشأته أنت. ≈ $10/شهر إضافية على خطة Pro |
| بيئة GitHub `staging` وسرّ `STAGING_DB_URL` فيها | ⏳ الخطوة 1 |
| الـ migrations والبيانات التجريبية | ⏳ تلقائياً بعد الخطوة 1 (سير العمل «Staging database») |
| إعدادات Auth لـ Staging | ⏳ الخطوة 2 |
| مشروع Vercel `classi-staging` | ⏳ الخطوة 3 (أداة Vercel لا تملك صلاحية إنشاء المشاريع) |
| أسرار اختبار Staging في GitHub | ⏳ الخطوة 4 |
| Turnstile لـ Staging | ⏳ الخطوة 5 (اختياري للاختبار الأول) |

## الخطوة 1: بيئتا GitHub (`staging-db` للقاعدة الكاملة، و`staging` للاختبارات)

**تحديث المرحلة 5:** الرابط الكامل `STAGING_DB_URL` ينتقل إلى بيئة منفصلة **`staging-db`**:
- مقصورة على فرع `staging-migrate`؛
- ويُفضَّل معها **Required reviewers** = أنت؛

فلا يصل إليه سير عمل الاختبارات أبداً. بيئة `staging` تبقى للاختبارات فقط: `STAGING_E2E_DB_URL`، وسرّ التجاوز، و`STAGING_URL`.

النص الأصلي للخطوة:

**لماذا بيئة لا سرّ عام:** سرّ المستودع العام يقرؤه أي فرع أو طلب دمج. سرّ البيئة لا يصل إلا للفرعين المسموحين.

1. GitHub ← المستودع ← Settings ← **Environments** ← **New environment** ← الاسم `staging`.
2. داخل البيئة ← **Deployment branches and tags** ← **Selected branches and tags** ← أضف `staging-test` و`staging-migrate`.
   - اختياري: **Required reviewers** = أنت، فلا يعمل أي تشغيل على Staging إلا بموافقتك.
3. داخل البيئة ← **Environment secrets** ← **Add secret**:
   - الاسم `STAGING_DB_URL`؛
   - القيمة: Supabase ← مشروع **classi-staging** ← **Connect** ← **Session pooler** ← الرابط، وكلمة المرور بدل `[YOUR-PASSWORD]`.
4. **إن كنت أضفت `STAGING_DB_URL` سابقاً كسرّ عام للمستودع** (Settings ← Secrets and variables ← Actions ← Repository secrets): احذفه من هناك بعد إضافته للبيئة.
5. اختياري (تحقق كامل من شهادة TLS): Supabase ← classi-staging ← Database ← Settings ← **SSL Configuration** ← Download certificate. ثم GitHub ← Settings ← Secrets and variables ← Actions ← **Variables** ← `SUPABASE_CA_CERT` = محتوى الملف. الشهادة عامة وليست سراً. بدونها الاتصال مشفّر، لكن دون التحقق من هوية الخادم.
6. أخبرني.

**ما أفعله بعدها:**
- أدفع الفرع `staging-migrate`، فيعمل سير العمل:
  - يتحقق أن الرابط لمشروع Staging لا الإنتاج؛
  - يطبّق الـ migrations الـ 30 بالترتيب، ثم seed؛
  - يضيف المهام المجدولة والتخزين؛
  - يضبط `dispatch_url` على تطبيق Staging بسرّ جديد؛
  - يحمّل البيانات الوهمية.
- ثم أتحقق عبر ربط Supabase.

## الخطوة 2: إعدادات Auth في Supabase (مشروع classi-staging فقط)

| المكان | الإعداد |
|---|---|
| Authentication ← Sign In / Providers ← **Phone** | مفعّل |
| Authentication ← **Hooks** ← Send SMS hook | Postgres function: `public.send_sms_hook` |
| Phone ← **Test phone numbers and OTPs** | `972500000001` إلى `972500000005`، ولكل رقم رمز من 6 أرقام تختاره (للدخول اليدوي بالأدوار: معلم، معهد، ولي أمر، طالب، مدير) |
| Authentication ← URL Configuration | Site URL = رابط Staging (بعد الخطوة 3) |

## الخطوة 3: مشروع Vercel لـ Staging (مجاني على Hobby)

1. Vercel ← Add New ← **Project** ← Import المستودع `aautel935-a11y/classi`:
   - Project Name: `classi-staging`؛
   - Framework: Next.js.
2. **Environment Variables قبل Deploy**، لبيئتي Production وPreview:

   | المتغير | القيمة |
   |---|---|
   | `NEXT_PUBLIC_SUPABASE_URL` | `https://nfipmylyahhogykikuqo.supabase.co` |
   | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | من Supabase ← classi-staging ← Project Settings ← API Keys ← **anon / publishable** (مفتاح عام، **ليس** service_role) |
   | `NEXT_PUBLIC_DEPLOY_ENV` | `staging` |
   | `SMS_019_TEST` | `1` |
   | `NEXT_PUBLIC_SITE_URL` | رابط Staging نفسه (بعد أول نشر)، حتى لا تشير روابط المشاركة والـ sitemap إلى classi.click |

   **لا تضف** `SMS_019_TOKEN` ولا `RESEND_API_KEY` ولا أي مفتاح من الإنتاج.
3. Deploy.
4. **الحماية:**
   - Settings ← **Deployment Protection** ← Vercel Authentication: **Standard Protection**.
   - Settings ← **Domains** ← احذف النطاق العام `classi-staging.vercel.app`. على خطة Hobby لا يمكن حماية النطاق العام، فيبقى الموقع متاحاً فقط عبر روابط النشر المحمية.
5. Settings ← Git ← Production Branch: `staging`. أنشئ أنا هذا الفرع من آخر commit ناجح في CI.

**الكود يحمي Staging أيضاً:**
- لا يُفهرس (`robots` و`X-Robots-Tag` و`meta`)؛
- يظهر شريط «نسخة تجريبية» في كل صفحة؛
- **لا SMS حقيقي إلا من نشر الإنتاج لمشروع نطاقه classi.click** (`VERCEL_ENV=production` و`VERCEL_PROJECT_PRODUCTION_URL` من Vercel نفسه). أي مشروع آخر، أو معاينة، أو تشغيل محلي، يستعمل وضع الاختبار في 019، حتى لو نُسي `NEXT_PUBLIC_DEPLOY_ENV`.

## الخطوة 4: إعدادات GitHub للاختبارات (يدوياً)

**بيئة `staging`** (Settings ← Environments ← staging):

| النوع | الاسم | القيمة |
|---|---|---|
| Deployment branches | — | `staging-test` **فقط** (احذف `staging-migrate` منها) |
| Required reviewers | — | أنت (موصى به) |
| Variable | `STAGING_URL` | `https://classi-staging.vercel.app` |
| Secret | `VERCEL_AUTOMATION_BYPASS_SECRET` | Vercel ← classi-staging ← Settings ← Deployment Protection ← Protection Bypass for Automation ← Add |
| Secret | `STAGING_OTP_TEACHER` | رمز `972500000001` كما وضعته في Supabase ← Authentication ← Phone ← Test numbers |
| Secret | `STAGING_OTP_INSTITUTE` | رمز `972500000002` |
| Secret | `STAGING_OTP_PARENT` | رمز `972500000003` |
| Secret | `STAGING_OTP_STUDENT` | رمز `972500000004` |
| Secret | `STAGING_OTP_ADMIN` | رمز `972500000005` |
| **احذف** | `STAGING_DB_URL` و`STAGING_E2E_DB_URL` | إن وُجدا هنا أو في Repository secrets. سير العمل يرفض التشغيل إن رآهما |

**بيئة `staging-db` (جديدة):**
- Deployment branches: `staging-migrate` فقط؛
- Required reviewers: أنت؛
- **بلا أسرار في الأوقات العادية.**

## تطبيق migrations جديدة على Staging (عند الحاجة فقط)

سير العمل «Staging database migrations» (`scripts/staging/migrate.sh`) يطبق **الـ migrations الجديدة فقط**:
- لا seed، ولا بيانات تجريبية، ولا إعادة تهيئة؛
- إعادة تشغيله بلا جديد لا تغيّر شيئاً، وهو يقارن عدد الصفوف قبل وبعد.

**يُشغَّل يدوياً فقط**، من فرع `staging-migrate`، ويُكتب تأكيد `migrate classi-staging`، وينتظر موافقتك في بيئة `staging-db`.

**أربعة فحوص قبل أي تغيير:**
1. الرابط يحمل معرّف classi-staging، ولا يحمل معرّف الإنتاج أبداً؛
2. معرّف قاعدة البيانات (cluster id) هو معرّف classi-staging؛
3. علامة `deploy_env = staging` موجودة؛
4. القاعدة مُجهّزة مسبقاً: سجل الـ migrations موجود، وعدد الحسابات معقول، و`dispatch_url` ليس الإنتاج.

**الخطوات:**
1. Supabase ← classi-staging ← Database ← Reset database password، وانسخ الرابط من Connect ← Session pooler.
2. GitHub ← Environments ← staging-db ← Secret `STAGING_DB_URL`.
3. Actions ← Staging database migrations ← Run workflow:
   - Branch: `staging-migrate`؛
   - التأكيد: `migrate classi-staging`؛
   - ثم وافق على التشغيل.
4. بعد النجاح: احذف السر، ثم Reset database password مرة أخرى.

`scripts/staging/setup.sh` يبقى لإعادة بناء Staging من الصفر فقط، ولا يستدعيه أي سير عمل.

**تنبيه:** رموز الاختبار في Supabase لها تاريخ انتهاء. حدّثها هناك وفي GitHub معاً عند انتهائها.

## الخطوة 5: Turnstile لـ Staging (اختياري)

1. Cloudflare ← Turnstile ← Add widget:
   - الاسم `classi-staging`؛
   - Domain: نطاق Staging؛
   - Managed.
2. Site key ← Vercel classi-staging: `NEXT_PUBLIC_TURNSTILE_SITE_KEY`.
3. Secret key 🔒 ← Supabase classi-staging ← Authentication ← Attack Protection ← Captcha.

## العزل عن الإنتاج

| ما يُفحص | الطريقة |
|---|---|
| قاعدة Staging ليست الإنتاج | سير العمل واختبارات المتصفح ترفض أي رابط بمعرّف الإنتاج، وتقبل فقط `nfipmylyahhogykikuqo`. ملف البيانات الوهمية يرفض أي قاعدة لم يعلّمها `setup.sh` كـ staging (`app_secrets.deploy_env`) |
| الأسرار لا تصل لغير Staging | في بيئة GitHub `staging` المقصورة على فرعين، وتُعطى فقط للخطوات التي تحتاجها (لا لتثبيت الحزم). أداة Supabase CLI مثبّتة بإصدار وبصمة commit |
| تطبيق Staging لا يكلّم قاعدة الإنتاج | متغيرات Vercel لـ Staging فقط. متغيرات مشروع الإنتاج صارت لبيئة Production وحدها (تحققت عبر الربط) |
| قاعدة Staging لا تستدعي تطبيق الإنتاج | `dispatch_url` يشير إلى Staging، ويُفحص بعد التجهيز |
| لا رسائل حقيقية | `NEXT_PUBLIC_DEPLOY_ENV=staging` يفرض وضع الاختبار (مختبَر)، ولا يوجد رمز 019 في Staging |
| لا بيانات حقيقية | البيانات مولّدة (`supabase/staging/staging_data.sql`). لا نسخ من الإنتاج |

## الاختبارات الآلية على Staging: دون أي اتصال بقاعدة البيانات (`tests/staging`)

**قرارك (2/11/2026):** لا حساب قاعدة بيانات للاختبارات. السبب في `SECURITY-NET-PERMISSIONS.md`.

**كيف تعمل:**
- **عبر التطبيق وSupabase Auth فقط.** لا رابط PostgreSQL ولا مفتاح service_role.
- **الحسابات الخمسة الثابتة وحدها،** برموزها الثابتة: `0500000001` إلى `0500000005`. لا تُنشأ حسابات جديدة.

**ما تختبره (على الهاتف وسطح المكتب):**
- النسخة معلَّمة وغير مفهرسة، ولا يظهر زر واتساب الدعم؛
- صفحة عرض تطلب الدخول قبل الحجز؛
- الصلاحيات: أربعة أدوار تُرفض في `/admin`، والمدير يدخل، وفحص الصحة يُظهر أن SMS غير مُعدّ؛
- لوحة المعلم ولوحة المعهد؛
- عزل البيانات: الطالب لا يرى ابن ولي الأمر ولا محادثاته؛
- حجز ثم إلغاؤه في التشغيل نفسه؛
- رسالة من ولي الأمر تصل المعلم، مع إشعار.

**قابلة للإعادة:** الحجز يُلغى في الاختبار نفسه. الرسائل تحمل علامة التشغيل، فتتراكم رسائل تجريبية فقط.

**تتوقف فوراً إذا:**
- كان العنوان غير `https://classi-staging.vercel.app`؛
- أو وُجد في البيئة رابط PostgreSQL، أو مفتاح `sb_secret_`، أو مفتاح service_role، أو قيمة تشير إلى الإنتاج؛
- أو حاول المتصفح الوصول إلى classi.click أو مشروع Supabase الإنتاجي. كل طلب يُفحص ويُمنع.

**لا يُحفظ شيء قد يحمل رمزاً أو جلسة:** لا traces، ولا لقطات شاشة، ولا فيديو، ولا تقرير HTML.

**تشغيل تجريبي في CI** (`STAGING_DRY_RUN`):
- الاختبارات نفسها على Supabase المحلي، بالحسابات والرموز نفسها (`supabase/config.toml`).
- يُزال `E2E_DB_URL` من بيئتها لإثبات أنها لا تحتاج قاعدة البيانات.
- كشف هذا التشغيل خللين في الحسابات التجريبية كانا سيمنعان الدخول على Staging، وأُصلحا في `supabase/staging/staging_auth_fix.sql`.

**قبل أول تشغيل على Staging الحقيقي: بموافقتك فقط.** يجب تطبيق `supabase/staging/staging_auth_fix.sql` على classi-staging:
- يكرر نفسه دون ضرر، ويخص الحسابات الخمسة فقط؛
- بدونه لن يستطيع أي حساب تجريبي الدخول.

**سرّ تجاوز حماية Vercel:**
- اختبارات المتصفح ترسله في رؤوس الطلب، ولخادم Staging فقط، لا في الرابط.
- Lighthouse يأخذ بدلاً منه ملف تعريف (cookie) قصير العمر خاصاً بالنشر، فلا يصل السر إلى Supabase أو غيره.
- تسجيل التتبع (traces) مُعطّل على Staging.
- لا تُرفع أي ملفات من التشغيل.

## الإيقاف الطارئ (Rollback) لنشر Staging ناجح

إعادة `exit 1` **لا تكفي**: فشل البناء الجديد لا يوقف النشر الناجح السابق. بالترتيب، الأسرع أولاً:

| # | الإجراء | الأثر |
|---|---|---|
| 1 | **إيقاف المشروع (Pause):** أنفّذه أنا عبر ربط Vercel (`pause_project`)، أو أنت بالأمر `vercel project pause classi-staging` | النشر الإنتاجي للمشروع وعنوانه `classi-staging.vercel.app` يتوقفان فوراً (`503 DEPLOYMENT_PAUSED`). يُلغى بـ unpause |
| 2 | Deployments ← **كل** نشر ناجح، بما فيها نشرات المعاينة (Preview) ← **Delete** | الإيقاف يشمل الإنتاج فقط، فهذا يزيل كل نسخة ناجحة، ولا يبقى رابط يعمل |
| 3 | Deployment Protection ← Protection Bypass for Automation ← **Revoke**، واحذف `VERCEL_AUTOMATION_BYPASS_SECRET` من GitHub | يبطل أي سر تجاوز مسرّب |
| 4 | Build Command ← `exit 1` | يمنع أي نشر جديد من فرع `staging` |
| 5 | (عند الحاجة) Supabase ← classi-staging ← API Keys ← تدوير مفتاح anon، و`alter role e2e_staging nologin;` | يقطع وصول أي نسخة قديمة للقاعدة |

**الحماية (Vercel Authentication على كل النشرات) تبقى مفعّلة في كل الأحوال**، فلا يصل للموقع إلا أعضاء فريق classi.

**موافقتك المسبقة (2/11/2026):** الخطوة 1 فقط (Pause لـ classi-staging)، وعند مشكلة أمنية خطيرة فقط. أنفّذها ثم أبلغك فوراً. حذف النشرات وأي خطوة أخرى تحتاج موافقتك في وقتها.
