# النسخ الاحتياطي المشفّر لإنتاج Classi (workflow: "Production backup")

**الحالة 20/11/2026:** جاهز ومختبر على بيانات وهمية فقط. **لم يُشغَّل.** يحتاج إعدادًا منك، ثم موافقتك على كل تشغيل.

## الفرق عن Staging

| البند | Staging backup | Production backup |
|---|---|---|
| البيئة في GitHub | `staging-db` | `production-db` (جديدة، تنشئها أنت) |
| السر | `STAGING_DB_URL` | `PRODUCTION_DB_URL` |
| الفرع المسموح | `staging-migrate` | `production-ops` |
| الهوية المطلوبة | cluster `7702070854497379551`، المشروع `nfipmylyahhogykikuqo`، علامة `staging` | cluster `7692130048193495360`، المشروع `rfxhqcagdsuhkjzwbawx`، علامة `production` أو بلا علامة (قبل الخطوة 0) |
| الاحتفاظ الافتراضي | 3 أيام | **يوم واحد** |
| المستودع العام | مسموح (الملف مشفّر) | **يرفض** إلا إذا اخترت صراحة `public_repo_ok = yes` |

بقية الطريقة نفسها: نسخة للقراءة فقط، ثم تشفير بمفتاحك العام، ثم استعادة إلى قاعدة فارغة ومعزولة داخل التشغيل، ثم مقارنة
أعداد الصفوف. يُحفظ ملف مشفّر واحد مع SHA-256 وملخص، ويتحقق job ثانٍ من الملف المحفوظ. الاختبار المحلي يغطي حالة الإنتاج
بلا علامة وبلا جدول تتبع (41/41)، ويرفض قاعدة عليها علامة staging أو مشروعًا آخر.

## الإعداد (مرة واحدة، نحو 10 دقائق، بعد إعداد Staging)

1. **المفتاح:** استخدم مفتاح age نفسه الذي أنشأته لـ Staging (`docs/v3/STAGING_BACKUP.md`)، أو أنشئ مفتاحًا منفصلًا
   للإنتاج إن أردت فصلًا أكبر.
2. GitHub → Settings → Environments → **New environment** → الاسم `production-db`:
   - Required reviewers: أنت، وفعّل «Prevent self-review» إن أضفت شخصًا آخر لاحقًا.
   - Deployment branches: **Selected branches** → `production-ops` فقط.
   - Secret `PRODUCTION_DB_URL`: من Supabase → classi → Connect → Session pooler. لا ترسله في المحادثة.
   - Variable `BACKUP_AGE_RECIPIENTS`: المفتاح العام `age1…`.
3. **الأفضل:** اجعل المستودع خاصًا قبل أول تشغيل. عندها تقتصر الملفات والسجلات عليك.
4. أطلب منك الموافقة على إنشاء الفرع `production-ops` من commit مراجَع (وVercel لا يبني هذا الفرع: `vercel.json`).

## التشغيل (موافقتك في كل مرة)

Actions → Production backup → Run workflow (الفرع production-ops) → اكتب `backup classi production` → وافق على البيئة
**بعد التأكد أن commit التشغيل هو المذكور في تقريري**. بعدها نزّل الملف المشفّر واحفظه خارج المزامنة (30 يومًا)، وتحقق منه:

```
age -d classi-backup.key.age | sh scripts/db/open-backup.sh classi-production-<stamp>.tar.age - مجلد-جديد
```

## الاستخدام في خطة الإطلاق

- **قبل الخطوة 0 وقبل أي migration:** نسخة واحدة مثبتة بالاستعادة (شرط GO).
- **تمرين النشر (C2/GO 2):** الملف نفسه يُستعاد في مشروع Supabase مؤقت أو قاعدة محلية، وتُطبّق عليه ملفات الإنتاج الـ 12
  للتأكد من البيانات الحقيقية (القيود الجديدة، التعبئة). هذا يتطلب فتح الملف، أي تعاملًا مع بيانات حقيقية بموافقتك.
- ملفات الصور في Storage غير مشمولة (كما في `backup.sh`). في الإنتاج اليوم ملف واحد فقط في الحاوية العامة.
