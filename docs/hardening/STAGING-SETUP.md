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
| سرّ `STAGING_DB_URL` في GitHub | ⏳ الخطوة 1 |
| الـ migrations والبيانات التجريبية | ⏳ تلقائياً بعد الخطوة 1 (سير العمل «Staging database») |
| إعدادات Auth لـ Staging | ⏳ الخطوة 2 |
| مشروع Vercel `classi-staging` | ⏳ الخطوة 3 (أداة Vercel لا تملك صلاحية إنشاء المشاريع) |
| أسرار اختبار Staging في GitHub | ⏳ الخطوة 4 |
| Turnstile لـ Staging | ⏳ الخطوة 5 (اختياري للاختبار الأول) |

## الخطوة 1: سرّ قاعدة Staging في GitHub

1. Supabase ← مشروع **classi-staging** ← **Connect** ← **Session pooler** ← انسخ الرابط، وضع كلمة المرور بدل `[YOUR-PASSWORD]`.
2. GitHub ← المستودع ← Settings ← Secrets and variables ← Actions ← **New repository secret**:
   - الاسم `STAGING_DB_URL`؛
   - القيمة: الرابط.
3. أخبرني.

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

   **لا تضف** `SMS_019_TOKEN` ولا `RESEND_API_KEY` ولا أي مفتاح من الإنتاج.
3. Deploy.
4. **الحماية:**
   - Settings ← **Deployment Protection** ← Vercel Authentication: **Standard Protection**.
   - Settings ← **Domains** ← احذف النطاق العام `classi-staging.vercel.app`. على خطة Hobby لا يمكن حماية النطاق العام، فيبقى الموقع متاحاً فقط عبر روابط النشر المحمية.
5. Settings ← Git ← Production Branch: `staging`. أنشئ أنا هذا الفرع من آخر commit ناجح في CI.

**الكود يحمي Staging أيضاً:**
- لا يُفهرس (`robots` و`X-Robots-Tag` و`meta`)؛
- يظهر شريط «نسخة تجريبية» في كل صفحة؛
- SMS يمر دائماً عبر وضع الاختبار في 019، حتى رموز الدخول.

## الخطوة 4: أسرار اختبار Staging في GitHub

| النوع | الاسم | من أين |
|---|---|---|
| Secret | `VERCEL_AUTOMATION_BYPASS_SECRET` | Vercel ← classi-staging ← Settings ← Deployment Protection ← **Protection Bypass for Automation** ← Add |
| Variable | `STAGING_URL` | رابط نشر Staging (`https://classi-staging-….vercel.app`) |
| Variable | `STAGING_APP_URL` | الرابط نفسه |

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
| قاعدة Staging ليست الإنتاج | سير العمل يرفض أي رابط بمعرّف الإنتاج، ويقبل فقط `nfipmylyahhogykikuqo` |
| تطبيق Staging لا يكلّم قاعدة الإنتاج | متغيرات Vercel لـ Staging فقط. متغيرات مشروع الإنتاج صارت لبيئة Production وحدها (تحققت عبر الربط) |
| قاعدة Staging لا تستدعي تطبيق الإنتاج | `dispatch_url` يشير إلى Staging، ويُفحص بعد التجهيز |
| لا رسائل حقيقية | `NEXT_PUBLIC_DEPLOY_ENV=staging` يفرض وضع الاختبار (مختبَر)، ولا يوجد رمز 019 في Staging |
| لا بيانات حقيقية | البيانات مولّدة (`supabase/staging/staging_data.sql`). لا نسخ من الإنتاج |
