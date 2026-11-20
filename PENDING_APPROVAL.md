# PENDING_APPROVAL — ما يحتاج موافقتك (تحديث 20/11/2026 صباحًا)

لا شيء من هذه البنود نُفّذ. كل بند يحتاج قرارك أو عملًا منك. القائمة مرتبة بالأولوية.

| # | البند | لماذا يحتاج موافقتك | ما المطلوب منك بالضبط |
|---|---|---|---|
| 1 | **إعداد النسخ الاحتياطي لـ Staging** (`staging-backup.yml`، الدليل `docs/v3/STAGING_BACKUP.md` بخطوات بسيطة) | إعدادات GitHub ووضع ملفات على فرع `staging-migrate` | مفتاح age على جهازك محمي بكلمة مرور، و`check-backup-key.sh` يعطي MATCH، والمتغير `BACKUP_AGE_RECIPIENTS` (المفتاح **العام** فقط) في `staging-db`، ووجود `STAGING_DB_URL` هناك، ثم موافقة على دفع الملفات إلى `staging-migrate` |
| 2 | تشغيل "Staging backup" مرة واحدة | تشغيل على Staging الحقيقي (قراءة فقط) | الموافقة على تشغيل البيئة في GitHub |
| 3 | **D-08 B على Staging** | تعديل قاعدة مستضافة | بعد نجاح البند 2. وإن مرّت 20/11 الساعة 19:14 فيلزم Probe جديد بموافقتك |
| 4 | إعدادات Production في Vercel: `CRON_SECRET`، `ADMIN_EMAIL`، `SUPABASE_SERVICE_ROLE_KEY` (Sensitive، للإنتاج فقط)، `NEXT_PUBLIC_TURNSTILE_SITE_KEY` | أسرار وإعدادات | تضيفها أنت. لا ترسل أي قيمة في المحادثة |
| 5 | Supabase Auth في الإنتاج: Captcha (Turnstile) وحماية كلمات المرور المسربة | إعدادات أمان | تفعّلها من لوحة Supabase |
| 6 | GitHub: قاعدة حماية على `main`، قرار جعل المستودع خاصًا، تفعيل تنبيهات Dependabot، إغلاق إنذار CodeQL الخاطئ في `/auth/confirm` | إعدادات أمان | تقرر وتنفذ أنت. **ملاحظة:** المستودع عام، فالسجلات والـ Artifacts مرئية لأي مستخدم مسجّل |
| 7 | **ملفات الإنتاج المحمية** (الخطوة 0 + 12 migration، `docs/v3/PRODUCTION_DEPLOY.md`) | تعديل على الإنتاج | كل ملف بموافقة منفصلة، بعد نسخة من الإنتاج مثبتة بالاستعادة، وتمرين على نسخة مستعادة (GO 2)، ونافذة صيانة للخطوات 07–09 |
| 8 | **نسخة احتياطية من الإنتاج** (`production-backup.yml` جاهز، `docs/v3/PRODUCTION_BACKUP.md`) | بيانات حقيقية وإعدادات GitHub | إنشاء البيئة `production-db` (مراجِع = أنت، الفرع `production-ops` فقط، السر `PRODUCTION_DB_URL`، المتغير `BACKUP_AGE_RECIPIENTS`)، وموافقة على إنشاء الفرع `production-ops`، والأفضل جعل المستودع خاصًا قبل أول تشغيل |
| 9 | v3 على Staging (ledger ثم business access) | تعديل قاعدة مستضافة | بعد البند 3 |
| 10 | الأسعار، وتاريخ الإطلاق، ومتى يُشغَّل `subscriptions_required`، ونص إشعار الزبون | قرارات تجارية وقانونية | قرارك |
| 11 | تدوير كلمة مرور قاعدة Staging (P5-2) | سر | من Supabase |
| 12 | نطاق نسخة الحرفيين: المهن الأولى، والبلدات، ومن يرى الطلب، واللغة (`docs/v3/SHARED_FOUNDATION.md` §5) | قرار منتج | قرارك قبل أي migration |
| 13 | الدمج في `main` ونافذة الصيانة والنشر على Production | نشر | لاحقًا، بعد البنود السابقة |
| 14 | أساس الحرفيين (`20261121000000_trades_foundation`، `docs/v3/SHARED_FOUNDATION.md` §7) | migration جديدة | محجوز: `migrate.sh` يرفضه على Staging حتى توافق. وقرارات النطاق في البند 12 قبل بناء الشاشات |
