# النسخ الاحتياطي المشفّر لـ classi-staging (workflow: "Staging backup")

**الحالة 20/11/2026:** الملفات جاهزة ومختبرة على بيانات وهمية فقط. لم يُشغَّل الـ workflow على Staging الحقيقي.

## ماذا يفعل تشغيل واحد

1. يتحقق أن الرابط هو classi-staging (وليس Production)، وأن cluster id = `7702070854497379551`، وأن علامة `staging` موجودة.
2. يأخذ نسخة بـ `scripts/db/backup.sh` (نفس السكربت الحالي): schema وdata (public, app_private, auth) وcounts وSHA256SUMS.
   كل البيانات من لقطة pg_dump واحدة (متسقة)، ويتحقق أن لا migration سُجّلت أثناء النسخ.
3. يشفّر النسخة بـ age إلى **مفتاحك العام** وإلى مفتاح مؤقت يُنشأ في التشغيل نفسه.
4. يفتح **الملف المشفّر نفسه** بالمفتاح المؤقت، **يحذف المفتاح المؤقت**، ثم يستعيد إلى قاعدة PostgreSQL 17 فارغة ومعزولة داخل
   نفس التشغيل بـ `scripts/db/restore-check.sh` → **PASS** فقط إذا تطابقت أعداد صفوف كل الجداول.
5. يحفظ الملف المشفّر + SHA-256 + ملخص أرقام (بلا بيانات)، ثم job ثانٍ بلا أسرار يعيد تنزيل الملف المحفوظ ويثبت أنه نفس الملف الذي استُعيد.

ما لا يفعله: لا يكتب في Staging (استعلامات قراءة فقط وpg_dump للقراءة)، لا push، لا نشر Vercel، لا migrations.
ملفات الصور في Storage غير مشمولة (كما في backup.sh).

## الإعداد اليدوي المطلوب منك (مرة واحدة)

1. **مفتاح التشفير على جهازك** (لا يُرسل لأحد): ثبّت age (Windows: `winget install FiloSottile.age`، Mac: `brew install age`) ثم
   `age-keygen -o classi-backup.key`. السطر `Public key: age1…` هو المفتاح **العام**.
   احفظ `classi-backup.key` في مكانين آمنين خارج المزامنة (مثلًا مدير كلمات المرور + USB). **فقدانه = لا يمكن فتح أي نسخة.**
2. GitHub → Settings → Environments → **staging-db** → Variables → `BACKUP_AGE_RECIPIENTS` = المفتاح العام (age1…).
   هذا متغير وليس سرًا، ولا يكفي لفتح النسخ.
3. تأكد أن السر `STAGING_DB_URL` موجود في staging-db (تعليق staging-migrate يقول إنه يُحذف بعد كل migration؛ إن حُذف أضفه قبل التشغيل).
4. وضع الـ workflow والسكربتات على فرع `staging-migrate` (البيئة staging-db تقبل هذا الفرع فقط). Vercel معطّل لهذا الفرع.
   إن لم يظهر زر Run workflow في Actions (GitHub يُظهره عادة للـ workflows الموجودة في main) فالتشغيل عبر:
   `gh workflow run staging-backup.yml --ref staging-migrate -f confirm="backup classi-staging"`.

## التشغيل

Actions → Staging backup → Run workflow (فرع staging-migrate) → اكتب `backup classi-staging` → اختر مدة الاحتفاظ → وافق على
البيئة staging-db. النتيجة في Summary: PASS + الحجم + SHA-256.

## أين تُحفظ النسخة ولماذا

المستودع **عام**: الـ Artifacts والسجلات يراها أي مستخدم GitHub مسجّل. لذلك:

| الطبقة | المكان | المدة |
|---|---|---|
| 1 | GitHub Artifact `classi-staging-backup-<run id>`: **ملف مشفّر فقط** (age: X25519 + ChaCha20-Poly1305) | 1 أو 3 أو 7 أيام (الافتراضي 3) ثم يحذفه GitHub |
| 2 | نسختك: تنزّل الملف إلى مكان خاص (Drive/USB) | 30 يومًا مقترحة، أو حتى نجاح الخطوة التالية بأسبوع |

لا أحد يفتح الملف بدون `classi-backup.key`. السجلات تطبع أرقامًا وأسماء جداول فقط؛ رسائل الأخطاء تُطبع بلا قيم.
بديل أقوى لاحقًا (يحتاج موافقتك وسرًا جديدًا): مستودع خاص للنسخ أو تخزين R2 المجاني.

## الاستعادة لاحقًا (من الملف المحفوظ فقط)

```sh
sha256sum -c classi-staging-<stamp>.tar.age.sha256
age -d -i classi-backup.key classi-staging-<stamp>.tar.age | tar -x
TARGET_URL='postgresql://…قاعدة فارغة غير Production…' sh scripts/db/restore-check.sh classi-backup-<stamp>
```

CI يجرّب هذا المسار بالضبط في كل تشغيل (job `backup-drill`) بمفتاح اختبار وبيانات وهمية.

## التكلفة

صفر: دقائق GitHub Actions مجانية للمستودعات العامة، والملف بحجم كيلوبايتات/ميغابايتات قليلة، وage وSupabase CLI مجانيان.
