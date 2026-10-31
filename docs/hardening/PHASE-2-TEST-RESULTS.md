# المرحلة 2: نتائج الاختبارات (31/10/2026، تشغيل محلي)

**البيئة:**
- Postgres 16 محلي يحاكي Supabase، بصلاحياته الافتراضية الحقيقية.
- بيانات اصطناعية فقط.
- Node 22 لاختبارات الوحدة.

**القاعدة:** ما لم يُشغَّل يُسجَّل **BLOCKED** ولا يُعدّ ناجحاً.

## الملخص

| النوع | ناجح | فاشل | معلّق | BLOCKED |
|---|---|---|---|---|
| مجموعات تكامل SQL | **22** | 0 | 0 | — |
| تأكيدات PASS/FAIL داخلها | **125** (أمن 91 + وظيفي 34) | 0 | 0 | — |
| اختبار التزامن (اتصالان حقيقيان) | **3** | 0 | 0 | — |
| فحص صلاحيات RPC | **1** (93 دالة) | 0 | 0 | — |
| تمرين التراجع (ملف down + 9 مجموعات) | **9** | 0 | 0 | — |
| اختبارات الوحدة (Node) | **37** | 0 | 0 | — |
| `tsc` (أنواع مبسطة) | ✅ 0 أخطاء | — | — | — |
| `next build` | — | — | — | **BLOCKED** |
| ESLint | — | — | — | **BLOCKED** |
| Playwright E2E (فحص عام + مسارات Staging) | — | — | — | **BLOCKED** (2 ملفان، 12 سيناريو) |
| axe و Lighthouse | — | — | — | **BLOCKED** |
| أجهزة حقيقية (iOS/Android، لوحة مفاتيح عربية) | — | — | — | **BLOCKED** |

## قبل وبعد

| الاختبار | قبل إصلاحات المرحلة 2 | بعدها | الدليل |
|---|---|---|---|
| `functional_test.sql` | **13 فاشلاً** من 28 فحصاً (أول نسخة) | 34/34 (مع فحوص المراجعة وصفحات المحادثة) | `evidence/phase2-functional-before.txt` و`…-after.txt` |
| اختبارات الوحدة | 28 ناجحاً، **3 فاشلة** (السبت، اليوم نفسه، ملف المرحلة 2 كله لعدم وجود الوحدات) | 37/37 | `evidence/phase2-unit-before.txt` و`phase2-unit.txt` |
| BUG-21 (المنطقة الزمنية) | `Asia/Jerusalem`: `2026-10-24T23:30Z` بدل `00:30Z` | متطابق تحت 3 مناطق | `evidence/phase2-tz-before.txt` |
| `security_test.sql` (المرحلة 1) | 90/90 | **91/91** (+ فحص مفتاح التراجع) | `evidence/phase2-security-after.txt` |
| المجموعات الـ 20 القديمة | كلها تنجح | كلها تنجح. أعداد الرفض المتوقعة لم تتغير، والفرق النصي في المخرجات مسافات فقط | `evidence/phase2-sql-suites.txt` |

## المجموعات (`sh supabase/tests/run_all.sh`)

| المجموعة | rc | رفض متوقع | النتيجة |
|---|---|---|---|
| admin_ops | 0 | 4 / 4 | ✅ |
| calendar | 0 | 6 / 6 | ✅ |
| e2e (سيناريو SQL كامل) | 0 | 2 / 2 | ✅ |
| flow | 0 | 7 / 7 | ✅ |
| **functional (جديد)** | 0 | 0 / 0، و34 PASS | ✅ |
| hardening | 0 | 2 / 2 | ✅ |
| launch | 0 | 4 / 4 | ✅ |
| messages | 0 | 6 / 6 | ✅ |
| moderation | 0 | 5 / 5 | ✅ |
| ops | 0 | 6 / 6 | ✅ |
| payments | 0 | 4 / 4 | ✅ |
| phone_login | 0 | 1 / 1 | ✅ |
| recurring | 0 | 4 / 4 | ✅ |
| reminders | 0 | 3 / 3 | ✅ |
| reports | 0 | 3 / 3 | ✅ |
| review | 0 | 2 / 2 | ✅ |
| roles | 0 | 4 / 4 | ✅ |
| security | 0 | 0 / 0، و91 PASS | ✅ |
| sms | 0 | 1 / 1 | ✅ |
| today | 0 | 0 / 0 | ✅ |
| trial_packages | 0 | 3 / 3 | ✅ |
| waitlist | 0 | 3 / 3 | ✅ |

## BLOCKED: لماذا وكيف تُشغَّل لاحقاً

| الاختبار | سبب الحجب | كيف يُشغَّل |
|---|---|---|
| `next build` + `tsc` الحقيقي + ESLint | سجل npm محجوب في بيئة العمل، فلا `node_modules` | على جهازك أو في CI: `npm ci && npx tsc --noEmit && npx next lint && npx next build` |
| Playwright: `tests/e2e/public.smoke.spec.mjs` | لا خادم للتطبيق، ولا وصول لـ classi.click | `BASE_URL=https://<staging> npx playwright test public.smoke` |
| Playwright: `tests/e2e/flows.staging.spec.mjs` | لا Staging | `STAGING=1 BASE_URL=… npx playwright test flows.staging` بأرقام Supabase التجريبية. **لا يُشغَّل على الإنتاج** |
| E2E للنقاط 🟠 في PHASE-2.md | كما أعلاه | سيناريوهات مقترحة: حفظ نموذج بخطأ ثم التأكد من بقاء المدخلات؛ محادثة بأكثر من 300 رسالة؛ عرض جديد قبل الملف؛ مجموعة بلا لقاءات؛ حضور بلا اختيار؛ فتح الإشعارات وانطفاء العدّاد |
| المُرسِل الحي | يحتاج مفاتيح 019 وResend حقيقية | على Staging مع `SMS_019_TEST=1` |
| axe وLighthouse وأجهزة حقيقية | لا متصفح متصل بالتطبيق | بعد Staging |

## أوامر إعادة التشغيل
```
sh supabase/tests/run_all.sh                 # 22 مجموعة
sh supabase/tests/concurrency_test.sh        # تزامن
sh supabase/tests/check_rpc_grants.sh        # صلاحيات RPC
sh supabase/tests/rollback_drill.sh supabase/rollback/20261031010000_functional_fixes.down.sql flow_test security_test
sh tests/run-unit.sh                          # الوحدة
```
