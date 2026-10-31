-- Classi demo data: invented teachers and institutes in Baqa and the Triangle.
-- Replace with real, verified listings before launch.

insert into public.subjects (name) values
 ('رياضيات'),('إنجليزي'),('عبري'),('عربي'),('فيزياء'),('كيمياء'),('أحياء'),('حاسوب'),('بسيخومتري')
on conflict do nothing;

insert into public.levels (name, sort) values
 ('ابتدائي',1),('إعدادي',2),('ثانوي',3),('بجروت 4 وحدات',4),('بجروت 5 وحدات',5),('بسيخومتري',6),('جامعي',7)
on conflict do nothing;

insert into public.teachers (name, town, subject_id, bio, years, is_school_teacher, verify, rating, reviews_count)
select v.name, v.town, s.id, v.bio, v.years, v.school, 'verified', v.rating, v.rev
from (values
 ('سامر مصاروة','باقة الغربية','رياضيات','معلم رياضيات في مدرسة ثانوية منذ 12 سنة، متخصص في بجروت 5 وحدات. أشرح خطوة بخطوة مع تمارين من امتحانات سابقة.',12,true,4.9,38),
 ('رنا أبو حسين','الطيبة','إنجليزي','معلمة إنجليزي، أركز على المحادثة والقراءة وتحضير امتحان البجروت الشفوي.',9,true,4.8,52),
 ('محمد غنايم','باقة الغربية','فيزياء','مهندس ومدرس فيزياء خصوصي. أربط القوانين بأمثلة من الحياة.',6,false,4.7,21),
 ('لينا جبارين','أم الفحم','أحياء','معلمة أحياء، أحضّر للمختبر ولامتحانات البجروت.',8,true,4.9,17),
 ('أحمد بيادسة','باقة الغربية','عبري','دروس عبري للطلاب العرب: قواعد، فهم مقروء، وكتابة.',5,false,4.6,29),
 ('هبة عثامنة','الطيبة','كيمياء','كيمياء للثانوي، مع ملخصات لكل وحدة.',7,false,4.8,24),
 ('خالد مواسي','باقة الغربية','حاسوب','مبرمج، أعلّم البرمجة لطلاب الثانوي والجامعة.',4,false,4.9,11),
 ('ديما قعدان','باقة الغربية','رياضيات','رياضيات للابتدائي والإعدادي، صبر وأسلوب ممتع للصغار.',6,false,4.7,33),
 ('يوسف عازم','الطيرة','عربي','معلم لغة عربية، نحو وأدب وتعبير.',15,true,4.8,19),
 ('سلمى زحالقة','كفر قرع','إنجليزي','إنجليزي للمرحلة الإعدادية، أونلاين فقط.',3,false,4.6,14),
 ('عمر ملحم','عرعرة','بسيخومتري','تحضير بسيخومتري، القسم الكمي واللغوي.',10,false,4.9,41),
 ('نور كبها','الطيرة','رياضيات','رياضيات 4 و5 وحدات، مجموعات صغيرة قبل الامتحانات.',7,true,4.7,22),
 ('إياد حاج يحيى','الطيبة','فيزياء','فيزياء 5 وحدات وميكانيكا جامعية.',9,false,4.8,27),
 ('مريم أبو مخ','باقة الغربية','عربي','معلمة ابتدائي، قراءة وكتابة للصفوف الأولى.',11,true,4.9,35),
 ('طارق مجادلة','جت','عبري','عبري محادثة وبجروت.',3,false,4.5,9),
 ('ريم إغبارية','أم الفحم','كيمياء','كيمياء عضوية وتحضير مختبر.',5,false,4.7,16)
) as v(name,town,subj,bio,years,school,rating,rev)
join public.subjects s on s.name = v.subj;

insert into public.institutes (name, town, bio, verify, rating, reviews_count) values
 ('مركز النخبة للتعليم','باقة الغربية','مركز تقوية ودورات بجروت في باقة منذ 2015، قاعات صغيرة حتى 14 طالباً.','verified',4.8,64),
 ('معهد المستقبل','الطيبة','لغات ومهارات دراسية للإعدادي والثانوي.','verified',4.7,40),
 ('أكاديمية الرواد','أم الفحم','برمجة وعلوم للأطفال والشباب.','verified',4.8,28),
 ('مركز إتقان','جت','عبري وإنجليزي للبجروت.','verified',4.6,19);

insert into public.rooms (institute_id, name, capacity)
select i.id, r.name, 14 from public.institutes i, (values ('قاعة 1'),('قاعة 2'),('قاعة 3')) r(name)
where i.name = 'مركز النخبة للتعليم';
insert into public.rooms (institute_id, name, capacity)
select i.id, 'القاعة الرئيسية', 12 from public.institutes i where i.name <> 'مركز النخبة للتعليم';

-- private lessons, groups and recorded content by teachers
insert into public.offerings (type, teacher_id, title, subject_id, level_id, places, price, seats, schedule_note, lessons_count, minutes)
select v.type::public.offering_type, t.id, v.title, t.subject_id, l.id, v.places::public.place_kind[], v.price, v.seats, v.note, v.lessons, v.minutes
from (values
 ('سامر مصاروة','private','رياضيات بجروت 5 وحدات','بجروت 5 وحدات','{home,online}',150,null,null,null,60),
 ('سامر مصاروة','group','مجموعة تقوية رياضيات، صف عاشر','ثانوي','{home}',60,6,'كل ثلاثاء 18:00',null,90),
 ('سامر مصاروة','recorded','الدوال من الصفر، 12 درساً مصوّراً','بجروت 5 وحدات','{online}',149,null,null,12,0),
 ('رنا أبو حسين','private','إنجليزي محادثة وبجروت','ثانوي','{home,online}',130,null,null,null,60),
 ('رنا أبو حسين','group','مجموعة أونلاين، تحضير الشفوي','بجروت 5 وحدات','{online}',50,8,'كل أحد 19:30',null,90),
 ('محمد غنايم','private','فيزياء ميكانيكا وكهرباء','بجروت 5 وحدات','{home}',160,null,null,null,60),
 ('لينا جبارين','private','أحياء ومختبر','ثانوي','{home,online}',130,null,null,null,60),
 ('لينا جبارين','group','مجموعة أحياء قبل الامتحان','بجروت 5 وحدات','{home}',55,6,'كل خميس 17:00',null,90),
 ('أحمد بيادسة','private','عبري للطلاب العرب','ثانوي','{online}',110,null,null,null,60),
 ('هبة عثامنة','private','كيمياء للثانوي','ثانوي','{home}',140,null,null,null,60),
 ('خالد مواسي','private','برمجة Python للمبتدئين','ثانوي','{online}',170,null,null,null,60),
 ('ديما قعدان','private','رياضيات ابتدائي وإعدادي','إعدادي','{home}',100,null,null,null,60),
 ('يوسف عازم','private','لغة عربية، نحو وتعبير','ثانوي','{home,online}',120,null,null,null,60),
 ('سلمى زحالقة','private','إنجليزي إعدادي','إعدادي','{online}',110,null,null,null,60),
 ('عمر ملحم','private','بسيخومتري كمي','بسيخومتري','{home,online}',180,null,null,null,60),
 ('عمر ملحم','recorded','القسم الكمي كاملاً، 30 درساً','بسيخومتري','{online}',199,null,null,30,0),
 ('نور كبها','group','رياضيات 4 وحدات، مجموعة صغيرة','بجروت 4 وحدات','{home}',55,5,'كل اثنين 17:30',null,90),
 ('إياد حاج يحيى','private','فيزياء 5 وحدات','بجروت 5 وحدات','{home,online}',160,null,null,null,60),
 ('مريم أبو مخ','private','قراءة وكتابة للصفوف الأولى','ابتدائي','{home}',100,null,null,null,60),
 ('طارق مجادلة','private','عبري محادثة','ثانوي','{home,online}',110,null,null,null,60),
 ('ريم إغبارية','private','كيمياء عضوية','بجروت 5 وحدات','{home}',150,null,null,null,60)
) as v(teacher,type,title,level,places,price,seats,note,lessons,minutes)
join public.teachers t on t.name = v.teacher
join public.levels l on l.name = v.level;

-- institute courses
insert into public.offerings (type, institute_id, course_teacher_id, title, subject_id, level_id, places, price, seats, schedule_note, start_date, sessions_count, minutes, default_room_id)
select 'course', i.id, t.id, v.title, s.id, l.id, v.places::public.place_kind[], v.price, v.seats, v.note, v.start::date, v.n, 90,
       (select r.id from public.rooms r where r.institute_id = i.id and r.name = v.room)
from (values
 ('مركز النخبة للتعليم','سامر مصاروة','دورة بجروت رياضيات 5 وحدات','رياضيات','بجروت 5 وحدات','{center}',850,14,'الأحد والأربعاء 17:00','2026-11-08',12,'قاعة 2'),
 ('مركز النخبة للتعليم','عمر ملحم','تحضير بسيخومتري مكثّف','بسيخومتري','بسيخومتري','{center,online}',900,14,'الاثنين والخميس 18:00','2026-11-15',24,'قاعة 3'),
 ('معهد المستقبل','رنا أبو حسين','إنجليزي محادثة للإعدادي','إنجليزي','إعدادي','{center}',550,12,'الثلاثاء 16:00','2026-11-03',10,'القاعة الرئيسية'),
 ('أكاديمية الرواد','خالد مواسي','برمجة للأطفال بلغة Scratch','حاسوب','ابتدائي','{center}',600,10,'الثلاثاء 15:30','2026-11-10',8,'القاعة الرئيسية'),
 ('مركز إتقان','طارق مجادلة','عبري للبجروت','عبري','ثانوي','{center,online}',700,12,'الخميس 17:00','2026-11-05',12,'القاعة الرئيسية')
) as v(inst,teacher,title,subj,level,places,price,seats,note,start,n,room)
join public.institutes i on i.name = v.inst
join public.teachers t on t.name = v.teacher
join public.subjects s on s.name = v.subj
join public.levels l on l.name = v.level;

insert into public.institute_teachers (institute_id, teacher_id, status, invited_at)
select distinct institute_id, course_teacher_id, 'accepted', null::timestamptz from public.offerings where type = 'course';

-- Generate dated sessions from the schedule note (weekday names + HH:MM).
create or replace function pg_temp.weekdays(note text) returns int[] language sql as $$
  select array_remove(array[
    case when note like '%أحد%' then 0 end, case when note like '%اثنين%' then 1 end,
    case when note like '%ثلاثاء%' then 2 end, case when note like '%أربعاء%' then 3 end,
    case when note like '%خميس%' then 4 end, case when note like '%جمعة%' then 5 end], null)
$$;

-- courses: sessions_count meetings from start_date
insert into public.sessions (offering_id, seq, starts_at, minutes, room_id)
select o.id, row_number() over (partition by o.id order by d)::int,
       ((d::date + (substring(o.schedule_note from '\d\d:\d\d'))::time) at time zone 'Asia/Jerusalem'),
       o.minutes, o.default_room_id
from public.offerings o
cross join lateral generate_series(o.start_date, o.start_date + 120, interval '1 day') d
where o.type = 'course' and extract(dow from d)::int = any (pg_temp.weekdays(o.schedule_note));
delete from public.sessions s using public.offerings o
where s.offering_id = o.id and o.type = 'course' and s.seq > o.sessions_count;

-- groups: the next 8 weeks
insert into public.sessions (offering_id, seq, starts_at, minutes)
select o.id, row_number() over (partition by o.id order by d)::int,
       ((d::date + (substring(o.schedule_note from '\d\d:\d\d'))::time) at time zone 'Asia/Jerusalem'),
       o.minutes
from public.offerings o
cross join lateral generate_series(current_date + 1, current_date + 56, interval '1 day') d
where o.type = 'group' and extract(dow from d)::int = any (pg_temp.weekdays(o.schedule_note));

-- weekly free hours: Sunday to Thursday, 15:00-21:00
insert into public.availability (teacher_id, weekday, start_time, end_time)
select t.id, w, '15:00', '21:00' from public.teachers t, generate_series(0,4) w;

-- Demo booking settings: a few offers with instant confirmation and weekly booking.
update public.offerings set auto_confirm = true, allow_weekly = true
 where title in ('رياضيات بجروت 5 وحدات', 'برمجة Python للمبتدئين', 'بسيخومتري كمي');
update public.offerings set allow_weekly = true
 where title in ('إنجليزي محادثة وبجروت', 'مجموعة تقوية رياضيات، صف عاشر', 'مجموعة أونلاين، تحضير الشفوي');
