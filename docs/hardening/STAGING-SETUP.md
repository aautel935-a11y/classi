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

## الخطوة 1: بيئة `staging` في GitHub وسرّ القاعدة داخلها

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

## الخطوة 4: أسرار اختبار Staging في GitHub

| النوع | الاسم | من أين |
|---|---|---|
| Secret **في بيئة `staging`** | `VERCEL_AUTOMATION_BYPASS_SECRET` | Vercel ← classi-staging ← Settings ← Deployment Protection ← **Protection Bypass for Automation** ← Add |
| Variable في بيئة `staging` | `STAGING_URL` | رابط نشر Staging (`https://classi-staging-….vercel.app`، بلا مسار بعده) |
| Variable في بيئة `staging` | `STAGING_APP_URL` | الرابط نفسه |

**بعدها:** أدفع الفرع `staging-test`، فيعمل سير العمل «Staging»، وفيه Playwright (هاتف وكمبيوتر) وaxe وLighthouse على Staging.

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
