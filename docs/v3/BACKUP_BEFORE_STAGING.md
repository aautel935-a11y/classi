# قبل تطبيق v3 على classi-staging: النسخ الاحتياطي وإثبات الاستعادة

تُنفَّذ هذه الخطوات **على جهازك**. الأسرار (رابط قاعدة البيانات وكلمة مرورها) لا تُكتب في المحادثة ولا في Git. كل أمر هنا يقرأ من
Staging فقط، ما عدا الاستعادة التي تكون في قاعدة **محلية** أو مشروع فارغ، **ولا تكون أبداً في Staging أو الإنتاج**.
الأدوات المطلوبة: `psql` و`pg_dump` (أو Supabase CLI) على جهازك.

## 1. النسخة التلقائية في Supabase (للعلم)

Supabase → classi-staging → Database → Backups: سجّل وقت أحدث نسخة يومية إن وُجدت. **لا تُعدّ دليلاً** على جاهزية
الاستعادة، لأنها لم تُختبر.

## 2. نسخة منطقية (قراءة فقط)

```sh
# الرابط: Supabase → classi-staging → Project Settings → Database → Connection string (Session pooler)
DB_URL='postgresql://postgres.nfipmylyahhogykikuqo:<password>@<host>:5432/postgres' \
  sh scripts/db/backup.sh ~/ClassiBackups
```

الناتج مجلد `classi-backup-<وقت>` فيه `schema.sql` و`data.sql` و`counts.txt` (عدد الصفوف لكل جدول، بلا محتوى) و`SHA256SUMS`.
السكربت يرفض الحفظ داخل مجلد المشروع، ويضبط الصلاحيات على المالك فقط. احفظ المجلد على قرص مشفّر واحذفه حين لا تحتاجه.

## 3. إثبات الاستعادة (إلزامي: بدونه NO-GO)

```sh
# قاعدة Postgres محلية فارغة (مثلاً: docker run -e POSTGRES_PASSWORD=x -p 55432:5432 postgres:17)
TARGET_URL='postgresql://postgres:x@127.0.0.1:55432/postgres' sh scripts/db/restore-check.sh ~/ClassiBackups/classi-backup-<وقت>
```

النتيجة المطلوبة: `PASS: … every row count matches the backup`. السكربت يرفض هدفاً هو مشروع الإنتاج، ويرفض هدفاً فيه أكثر من 20
حساباً. في CI يُجرى التمرين نفسه على كل commit (نجح: 70 جدولاً، كل الأعداد متطابقة).

## 4. البصمة قبل التطبيق (قراءة فقط)

في SQL Editor لـ classi-staging شغّل `supabase/staging/snapshot_v3.sql`. الملف يبدأ بـ `begin read only` وينتهي بـ
`rollback`. احفظ الصفوف الأربعة الناتجة مع النسخة:

- **data**: عدد صفوف كل جدول قبل v3.
- **settings**: الإعدادات، عدا مفاتيح v3 الثلاثة.
- **migrations**: الـ migrations المسجلة.
- **visible**: ما يراه الزائر (المعلمون، المعاهد، العروض).

بعد التطبيق يطبع `verify_v3.sql` البصمات نفسها، **ويجب أن تتطابق**. استثناء وحيد: إن حجز أحد أو سجّل في الدقائق بين البصمتين
تتغير بصمة data، فاختر وقتاً هادئاً.

## 5. ما يُفقد عند التراجع

| الملف | يرفض إن | يحذف |
|---|---|---|
| `rollback_20261120010000_v3_business_access.sql` | وُجد أي صف تجربة أو إعفاء أو سعر قبل الخصم | لا شيء |
| `rollback_..._v3_business_access_discard_data.sql` | — | صفوف التجارب والإعفاءات، أسعار ما قبل الخصم وأسبابه، إعدادات `trial_days` و`grace_days` و`launch_at` |
| `rollback_20261120000000_v3_ledger.sql` | وُجد أي مستحق أو دفعة أو سطر تدقيق أو صلاحية طاقم | لا شيء |
| `rollback_..._v3_ledger_discard_data.sql` | — | **كل المستحقات والدفعات والتصحيحات وسجل التدقيق وصلاحيات الطاقم** |

في كل الحالات تبقى الحجوزات والحسابات والاشتراكات وحالة الدفع القديمة كما هي. ملفات `_discard_data` تطبع عدد ما تحذفه، وهي
لبيانات الاختبار فقط، أو بعد تصدير البيانات (CSV من `/ledger` أو نسخة القسم 2).
