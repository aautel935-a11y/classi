# خطة التراجع (Rollback) — فرع hardening/production-readiness

**المبدأ** (تحديث المرحلة 2): التراجع يكون **دقيقاً لكل تغيير، ويحافظ على الصلاحيات الآمنة وسلامة البيانات**.

**ممنوع كحل سريع:**
- إعادة منح EXECUTE لكل الدوال إلى PUBLIC أو anon أو authenticated، لأنها تعيد ثغرة SEC-01.
- حذف أو تعطيل triggers الحماية بشكل دائم: `*_active_writer`، `bookings_zzz_rules`، `children_guard_delete`، `offerings_course_teacher_guard`.

هذه الأوامر حُذفت من هذه الخطة.

---

## 1. فحوص قبل النشر (قراءة فقط، في محرر SQL على الإنتاج)
1. **صور خارج تخزين Supabase.** يجب أن تكون النتيجة 0 في الصفوف الثلاثة، وإلا تُصحَّح الروابط أولاً.
   ```sql
   select 'teacher' t, count(*) from teachers where photo_url is not null and photo_url !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/'
   union all select 'institute', count(*) from institutes where logo_url is not null and logo_url !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/'
   union all select 'profile', count(*) from profiles where avatar_url is not null and avatar_url !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/';
   ```
2. **دوال إضافات داخل `public`.** المطلوب 0.
   ```sql
   select count(*) from pg_proc p join pg_depend d on d.objid = p.oid and d.deptype = 'e' where p.pronamespace = 'public'::regnamespace;
   ```
3. **مدد اللقاءات خارج 10–480 دقيقة.** إن لم تكن النتيجة 0، فتعديل تلك اللقاءات لاحقاً سيُرفض.
   ```sql
   select count(*) from sessions where minutes not between 10 and 480;
   ```
4. **أطفال لهم حجوزات قادمة** (للمعرفة فقط): بعد النشر لن يُحذفوا إلا بعد إلغاء الحجوزات.
   ```sql
   select count(distinct child_id) from bookings where child_id is not null and status in ('pending','confirmed') and starts_at > now();
   ```

## 2. ترتيب النشر (عند الموافقة فقط)
1. **نسخة احتياطية:** من Supabase (Database → Backups) أو `supabase db dump -f backup-YYYYMMDD.sql`. احفظها خارج الجهاز.
2. **Staging:** تطبيق `20261031000000_production_hardening.sql` ثم `20261031010000_functional_fixes.sql`، ثم البناء واختبارات E2E.
3. **الإنتاج:** الـ migrationان بالترتيب نفسه، ثم فحص SEC-01 (القسم 4).
4. **نشر التطبيق** (دمج الفرع في `main`).

**القاعدة الجديدة متوافقة مع التطبيق الحالي:** المسارات القديمة تعمل، وترجع رسائل رفض عربية حيث مُنعت الإساءة.

**فرق واحد يجب معرفته:** التطبيق القديم يتجاهل الخطأ عند حذف طفل. لذلك، بين نشر القاعدة ونشر التطبيق، يضغط ولي الأمر «حذف» لطفل له حصص قادمة، فلا يحدث شيء ولا تظهر رسالة.

**الترتيب الأفضل:** القاعدة أولاً، ثم التطبيق مباشرة.

## 3. التراجع عن التطبيق
في Vercel: Deployments ← آخر نشر قبل الدمج ← **Instant Rollback**. القاعدة لا تتأثر، والتطبيق القديم يعمل مع القاعدة الجديدة (انظر أعلاه).

## 4. التراجع الدقيق عن القاعدة، تغييراً تغييراً

> كل الأوامر تُنفَّذ في محرر SQL. «يبقى محمياً» يعني ما لا يتأثر بالتراجع.

### المرحلة 1: `20261031000000_production_hardening.sql`

| التغيير | العَرَض المحتمل | التراجع الدقيق | يبقى محمياً |
|---|---|---|---|
| SEC-01: قائمة EXECUTE | `permission denied for function X` في ميزة | `grant execute on function public.X(<args>) to authenticated;` (أو `anon` إن كانت صفحة عامة)، **للدالة المحددة فقط**، ثم أضفها إلى القائمة في migration لاحق. لمعرفة التوقيع: `select oid::regprocedure from pg_proc where proname='X';` | كل الدوال الداخلية الأخرى |
| SEC-01: التحقق بعد النشر | — | `select p.oid::regprocedure from pg_proc p where p.pronamespace='public'::regnamespace and has_function_privilege('authenticated', p.oid, 'execute') order by 1;` يجب أن تطابق القائمة في القسم 9 من الـ migration | — |
| سقف SMS | رسائل ضرورية لا تُرسل | رفع الحد: `insert into app_settings(key,value) values ('sms_daily_cap_per_user','10') on conflict (key) do update set value=excluded.value;` (والسقف العام `sms_daily_cap`، الافتراضي 400) | الحد يبقى موجوداً |
| حدود رموز الدخول | أرقام حقيقية تُرفض | المفتاحان `otp_per_hour` (افتراضي 5) و`otp_per_day` (افتراضي 15) | الأرقام غير الإسرائيلية تبقى مرفوضة |
| حد الحجوزات المفتوحة | طالب صادق يُرفض | `max_open_bookings_per_offer` (افتراضي 8) | باقي قواعد الحجز |
| قاعدة ساعات المعلم | حجز صحيح يُرفض بسبب الساعات | **مفتاح مؤقت:** `insert into app_settings(key,value) values ('rule_teacher_hours','off') on conflict (key) do update set value='off';` ثم احذفه بعد الإصلاح: `delete from app_settings where key='rule_teacher_hours';` (جُرّب: يرفع قاعدة الساعات وحدها) | طريقة الدفع، تكرار المقعد، الحد الأعلى، قفل المعهد |
| حد دعوات الطاقم | معهد كبير يحتاج أكثر | `staff_invites_per_day` (افتراضي 10) | الموافقة إلزامية |
| موافقة المعلم على الطاقم | معلم بلا حساب لا يُضم | **لا تراجع للقيد.** الحل: أن يُنشئ المعلم حساباً ويقبل الدعوة. أو يضيفه الأدمن (`postgres`) يدوياً بعد موافقته المكتوبة: `insert into institute_teachers(institute_id, teacher_id, status) values (…, …, 'accepted');` | التقويم لا يُعطَّل بدورة وهمية |
| حماية الحسابات الموقوفة | موقوف يحتاج إنهاء أمر | فكّ الإيقاف من لوحة الأدمن، أو الأدمن ينفذ العملية بنفسه (الأدمن مستثنى). **لا تحذف الـ trigger** | — |
| منع الحذف المتسلسل | معلم يريد حذف عرض له حجوزات | يخفي العرض (active=false) بدل الحذف. لا تراجع مطلوب | السجلات المالية والتقييمات |
| أعمدة الزوار (SEC-19/20) | صفحة عامة تفشل بـ `permission denied for table` | منح العمود المحدد فقط: `grant select (col) on public.<table> to anon;` | الأعمدة الداخلية الأخرى |
| قيود روابط الصور | تحديث صف قديم يفشل | تصحيح الرابط في ذلك الصف (الفحص 1). **لا تحذف القيد** | — |
| تراجع كامل عن المرحلة 1 | — | **غير مستحسن.** إن لزم: استعادة النسخة الاحتياطية (القسم 5) | — |

### المرحلة 2: `20261031010000_functional_fixes.sql`

- **أولاً** تراجع عن التطبيق، لأنه يستدعي `replace_availability`.
- **ثم:** `supabase/rollback/20261031010000_functional_fixes.down.sql`. يحذف الـ triggers الثلاثة والدالة، ويبقي عمود `hours_confirmed_at` لأنه غير ضار.
- **جُرّب:** `supabase/tests/rollback_drill.sh` بنى القاعدة، وطبّق ملف التراجع، ثم شغّل 9 مجموعات. **كلها نجحت، ومنها `security_test`**، أي أن حماية المرحلة 1 بقيت كاملة (`evidence/phase2-rollback-drill.txt`).

**تراجع جزئي داخل المرحلة 2:**

| التغيير | التراجع |
|---|---|
| مهلة الساعتين لحجز اليوم نفسه | `min_lead_minutes` (افتراضي 120) |
| منع حذف طفل له حجوزات | لا تراجع. إلغاء الحجوزات القادمة هو المسار الصحيح، ورسالة الرفض تشرح ذلك |
| مزامنة الحضور مع التقرير | `drop trigger attendance_to_report on public.attendance;` (ليس trigger حماية، والأثر عرضي فقط) |

## 5. التراجع الكامل
استعادة النسخة الاحتياطية من الخطوة 2.1. تضيع البيانات المكتوبة بعد النشر، لذلك تُستخدم **فقط** إذا فشل التراجع الدقيق.

## 6. ما يمنع النشر التلقائي من هذا الفرع
- **الفرع لم يُرفع إلى GitHub** (Vercel ينشر كل فرع يُرفع كمعاينة، وقد تتصل بقاعدة الإنتاج).
- **لا اتصال بقاعدة الإنتاج من بيئة العمل.** كل الاختبارات على Postgres محلي ببيانات اصطناعية.

## 7. ما جُرّب وما لم يُجرَّب
- ✅ **مفتاح `rule_teacher_hours`:** يرفع قاعدة الساعات وحدها. فحص داخل `security_test`.
- ✅ **ملف التراجع للمرحلة 2:** 9 مجموعات تنجح بعده، ومنها اختبار الأمن.
- ✅ **مفاتيح الإعدادات** (SMS، OTP، الحجوزات، الدعوات): تُستخدم في الاختبارات بقيم مخفّضة.
- ⚪ **استعادة نسخة احتياطية حقيقية من Supabase:** لم تُجرَّب، لا وصول للإنتاج. **مطلوبة قبل الإطلاق.**
