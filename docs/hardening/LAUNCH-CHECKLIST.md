# قائمة الإطلاق: الإعدادات، المتغيرات، ترتيب الـ migrations، والنشر التدريجي

**لا قيم أسرار في هذا الملف.** القيم تُكتب مباشرة في Vercel وSupabase، ولا تُرسل في محادثة أو ملف.

**الرموز:**
- 🔒 سرّ: لا يُعرض ولا يُرسل.
- 🌐 عام: يظهر في المتصفح، لكنه خاص بكل بيئة.
- ⚠️ نقطة توقف: لا يُتابَع بعدها دون موافقتك.

---

## 1. متغيرات Vercel

**القاعدة:**
- قيم الإنتاج في بيئة **Production** فقط.
- **Preview** يأخذ قيم Staging، أو لا يأخذ شيئاً.

**تحقق من الحالة الحالية بنفسك** (لم أستطع رؤية لوحة Vercel):
1. افتح Vercel ← Project ← Settings ← Environment Variables.
2. تأكد أن `NEXT_PUBLIC_SUPABASE_URL` الخاص بالإنتاج **غير مفعَّل** لبيئة Preview.

| المتغير | النوع | Production | Staging / Preview | الاستعمال في الكود |
|---|---|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | 🌐 | عنوان مشروع الإنتاج | عنوان مشروع Staging | كل الاتصالات بقاعدة البيانات |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | 🌐 | مفتاح anon للإنتاج | مفتاح anon لـ Staging | نفسه. مفتاح عام، صلاحياته تحددها RLS |
| `NEXT_PUBLIC_SITE_URL` | 🌐 | `https://classi.click` | عنوان Staging | الروابط في الرسائل، sitemap، canonical |
| `NEXT_PUBLIC_TURNSTILE_SITE_KEY` | 🌐 | مفتاح موقع Turnstile للإنتاج | مفتاح Staging (widget منفصل)، أو فارغ | مربع «لست برنامجاً» في الدخول. **فارغ = معطّل** |
| `CRON_SECRET` | 🔒 | قيمة عشوائية طويلة | قيمة مختلفة | حماية `/api/health/cron` (فحص يومي يرسل تنبيهاً). **ناقص الآن (A5)** |
| `ADMIN_EMAIL` | بيانات شخصية | بريد المدير | بريدك أو فارغ | وجهة تنبيه الفحص اليومي. **ناقص الآن (A5)** |
| `RESEND_API_KEY` | 🔒 | مفتاح Resend | مفتاح منفصل أو فارغ | رسائل البريد (تذكيرات، رمز الدخول عند تعذر SMS، التنبيهات) |
| `REMINDER_FROM_EMAIL` | — | مثل `Classi <noreply@…>` | نفسه أو فارغ | مرسل التذكيرات |
| `ALERT_FROM_EMAIL` | — | اختياري | اختياري | مرسل التنبيهات (وإلا `REMINDER_FROM_EMAIL`) |
| `SMS_019_TOKEN` | 🔒 | رمز API من 019 | **فارغ أو رمز تجريبي** | إرسال SMS |
| `SMS_019_USER` | 🔒 | اسم حساب 019 | نفسه | نفسه |
| `SMS_SENDER` | — | `Classi` (أو الاسم المعتمد لدى 019) | نفسه | اسم المرسل الظاهر (حتى 11 حرفاً إنجليزياً) |
| `SMS_019_TEST` | — | **غير موجود** | `1` | يفحص الطلب عند 019 **دون إرسال** |

**لا حاجة في Vercel** لـ `service_role` ولا لأي مفتاح قاعدة بيانات: التطبيق لا يستعملهما (تحققت من الكود).

## 2. إعدادات داخل قاعدة البيانات (جدول `app_secrets`، لكل مشروع)

قاعدة البيانات هي التي تستدعي التطبيق: الإشعارات وSMS كل دقيقة عبر pg_cron وpg_net.

| المفتاح | النوع | Production | Staging |
|---|---|---|---|
| `dispatch_url` | — | `https://classi.click/api/push/dispatch` | `https://<staging>/api/push/dispatch` |
| `dispatch_secret` | 🔒 | عشوائي | عشوائي **مختلف**. يضعه `scripts/staging/setup.sh` دون عرضه |
| `vapid_public` / `vapid_private` / `vapid_subject` | 🔒 (الخاص) | مفاتيح Push | فارغة (Push معطّل) أو مفاتيح منفصلة |

⚠️ **خطر يجب منعه:** Staging الذي يحمل `dispatch_url` الإنتاج يرسل طلبات إلى تطبيق الإنتاج. لذلك:
- السكربت يرفض عنوان `classi.click`.
- السكربت يطبع `dispatch_url points at production: false`.

## 3. Supabase (لوحة كل مشروع)

| المكان | الإعداد | القيمة المطلوبة |
|---|---|---|
| Authentication ← URL Configuration | Site URL | `https://classi.click` (Staging: عنوانه) |
| | Redirect URLs | `https://classi.click/auth/callback`، و`/auth/confirm` |
| Authentication ← Providers ← Phone | Enable phone | مفعّل |
| Authentication ← Hooks | Send SMS hook | Postgres function `public.send_sms_hook` (يكتب في `otp_outbox`، والتطبيق يرسل عبر 019) |
| Authentication ← Rate limits | SMS / OTP | حدود Supabase، ومعها حدودنا في القاعدة (`otp_per_hour`=5، `otp_per_day`=15، `sms_daily_cap`=400) |
| Authentication ← Attack Protection | **CAPTCHA** | Turnstile + المفتاح السري 🔒. **فعّله فقط بعد ضبط `NEXT_PUBLIC_TURNSTILE_SITE_KEY` ونشر التطبيق**، وإلا يتوقف الدخول |
| Authentication ← Providers ← Email | Secure password change | مفعّل (SEC-34) |
| Authentication ← Email | Confirm email | كما هو حالياً |
| API ← Data API | Exposed schemas | `public` فقط. **لا تضف `app_private`** |
| API ← Data API | Max rows | 1000 (الافتراضي). المرحلة 4 تقرأ بصفحات حيث يلزم |
| Database ← Extensions | `pg_cron`، `pg_net` | مفعّلة (تستعملها الإشعارات والتذكيرات) |
| Database ← Backups | | الخطة المجانية: لا نسخ تلقائية قابلة للتنزيل. استعمل `scripts/db/backup.sh` (`BACKUP-RESTORE.md`) |
| Storage | bucket `avatars` | عام، 2MB، صور فقط (ينشئه الـ migration) |

## 4. Cloudflare Turnstile (مجاني)

1. Cloudflare ← Turnstile ← Add widget.
2. أنشئ widget للإنتاج:
   - الاسم `Classi`؛
   - Domains: `classi.click`؛
   - Mode: **Managed**.
3. أنشئ widget **ثانياً** لـ Staging، بنطاق Staging.
4. ضع **Site key** في Vercel (`NEXT_PUBLIC_TURNSTILE_SITE_KEY`) لكل بيئة.
5. ضع **Secret key** 🔒 في Supabase ← Authentication ← Attack Protection ← Captcha (provider: Turnstile).
6. **الترتيب:**
   - انشر التطبيق مع site key أولاً، وتحقق أن المربع يظهر في `/login`.
   - بعدها فعّل Captcha في Supabase.
   - جرّب الدخول بالهاتف، وبالبريد، وإعادة كلمة المرور. الطرق الثلاث ترسل الرمز (إصلاح المرحلة 3).

## 5. 019 (SMS)

| البند | المطلوب |
|---|---|
| حساب | حساب 019 فعّال برصيد كافٍ. السقف اليومي في القاعدة: 400 رسالة، و6 لكل مستخدم (قابلة للتعديل من لوحة الأدمن) |
| API token | 019 ← Settings ← API Token Management ← رمز جديد للإنتاج 🔒، ورمز آخر لـ Staging إن أمكن |
| اسم المرسل | `Classi` معتمد لدى 019 (بعض المشغّلين يطلبون تسجيله) |
| Staging | `SMS_019_TEST=1`: يتحقق من الطلب دون إرسال. للتجربة الحقيقية: رقمك فقط، ثم أعد `SMS_019_TEST=1` |
| مراقبة | لوحة الأدمن ← تبويب العمليات: إحصاءات SMS (`admin_sms_stats`) |

## 6. ترتيب الـ migrations (تحقق آلي)

| # | الملف | المرحلة | يعتمد على |
|---|---|---|---|
| 1 | `20261031000000_production_hardening.sql` | 1: الأمن | كل ما قبله (حتى `20261027020000_support.sql`) |
| 2 | `20261031010000_functional_fixes.sql` | 2: الأعطال الوظيفية | 1 (مفتاح `rule_teacher_hours`) |
| 3 | `20261031020000_phase3_performance_settings.sql` | 3: فهارس، إعدادات، إصلاح نشر العروض والأوقات | 2 (`replace_availability`) |
| 4 | `20261101000000_phase4_performance.sql` | 4: الأداء والبحث | 3 (`owner_bookings(uuid, timestamptz)`) |

**الأدلة على الترتيب:**
- تُطبَّق الأربعة بالترتيب على Supabase حقيقي (محلي) في كل تشغيل CI، ويعمل التطبيق فوقها (28 اختبار متصفح).
- كل ملف آمن على قاعدة حية: دوال وفهارس وسياسات، **دون تعديل بيانات**.
- **التطبيق القديم يعمل مع القاعدة الجديدة** في كل مرحلة، لأن المعاملات الجديدة اختيارية.

**قبل التطبيق على الإنتاج (قراءة فقط):** آخر migration مسجَّل يجب أن يكون `20261027020000`. إن وُجد غيره، أتوقف وأراجع.
```sql
select version, name from supabase_migrations.schema_migrations order by version desc limit 5;
```

## 7. Staging

| الخطوة | من | التكلفة |
|---|---|---|
| مشروع Supabase ثالث (`classi-staging`) | أنت | **يحتاج خطة Pro**: $25 للمنظمة + $10 لكل مشروع بعد الأول ≈ **$45/شهر** لثلاثة مشاريع. الخطة المجانية محدودة بمشروعين نشطين، وmajd.dev لا يُوقف |
| تطبيق Staging على Vercel | أنت | مشروع Vercel منفصل (`classi-staging`) مربوط بالمستودع نفسه، فرعه `staging`، ومتغيراته من القسم 1. لا يمسّ إعدادات مشروع الإنتاج. **إن كان حسابك Hobby:** شروط Vercel تقصره على الاستخدام غير التجاري، وPro = $20/شهر |
| تجهيز القاعدة | أنا بعد موافقتك، أو أنت | `STAGING_DB_URL=… STAGING_APP_URL=… sh scripts/staging/setup.sh`. يرفض مشروع الإنتاج وعنوان `classi.click`، ولا يطبع أسراراً |
| إعدادات Auth لـ Staging | أنت | القسم 3، بعناوين Staging |
| اختبارات | أنا | `BASE_URL=https://<staging> E2E_DB_URL=<staging> npx playwright test` (لا يقبل `classi.click`) |

**البديل المجاني المعمول به الآن:** Supabase كامل يعمل داخل كل تشغيل CI (يُنشأ ويُحذف كل مرة). يكفي للاختبارات الآلية، لكنه لا يجرّب SMS الحقيقي ولا الهاتف الحقيقي.

## 8. النشر التدريجي (كل خطوة بنقطة توقف)

| المرحلة | ما يحدث | من | التحقق | ⚠️ توقف إذا |
|---|---|---|---|---|
| 0. تحضير | نسخة احتياطية + **تجربة استعادتها** في مشروع غير الإنتاج (`BACKUP-RESTORE.md`)، وضبط متغيرات القسم 1 | أنت (أو أنا بإذنك للنسخة: قراءة فقط) | `restore-check.sh` يطبع PASS | لم تنجح الاستعادة |
| 1. Staging | `setup.sh`، نشر الفرع على `classi-staging`، Playwright على Staging، تجربة يدوية على iPhone وAndroid | أنا + أنت | 28/28 + قائمة يدوية: دخول، حجز، إلغاء، رسالة، إشعار | أي فشل |
| 2. فحص الإنتاج (قراءة فقط) | الفحوص الأربعة في `ROLLBACK.md` §1 + استعلام القسم 6 + نسخة احتياطية **قبل النشر مباشرة** | أنت أو أنا بإذنك | النتائج كما هو متوقع | أي نتيجة غير متوقعة |
| 3. القاعدة | تطبيق الـ migrations **واحداً واحداً** في ساعة هادئة | أنا بموافقتك الصريحة | بعد كل ملف: استعلام SEC-01، وفتح الصفحة الرئيسية والبحث وصفحة عرض (التطبيق القديم ما زال يعمل) | خطأ في ملف ← التراجع الدقيق لذلك الملف (`ROLLBACK.md` §4) |
| 4. التطبيق | دمج الفرع في `main` ← نشر Vercel للإنتاج | أنت (الدمج = قرار النشر) | خلال 15 دقيقة: الصفحات العامة، دخول برقمك، حجز تجريبي بحساب تجريبي ثم إلغاؤه، الإشعارات، لوحة المعلم | خطأ ظاهر ← Vercel Instant Rollback (دقيقة واحدة) |
| 5. Captcha | ضبط Turnstile (القسم 4)، ثم تفعيله في Supabase | أنت | دخول بالهاتف والبريد | فشل الدخول ← أطفئ Captcha في Supabase فوراً |
| 6. مراقبة 24–48 ساعة | Vercel Logs (`[unmapped error]`، `[schedule]`)، بريد الفحص اليومي، إحصاءات SMS، شكاوى المستخدمين | أنت + أنا | لا أخطاء جديدة | أخطاء متكررة ← تحليل، ثم تراجع جزئي إن لزم |
