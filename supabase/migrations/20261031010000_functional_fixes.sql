-- Classi: functional fixes, phase 2 (BUG-02, BUG-04, BUG-05, BUG-13, BUG-26 in CLASSI_BUG_REPORT.md).
-- Additive and safe on a live database: one new column (backfilled for teachers who already changed their hours),
-- new functions and triggers; no row is deleted.

------------------------------------------------------------------------------------------------------------
-- BUG-04 + BUG-13: weekly hours are saved in one transaction (all or nothing), validated in the database,
-- and the save records that the teacher really chose them.
------------------------------------------------------------------------------------------------------------
alter table public.teachers add column if not exists hours_confirmed_at timestamptz;
-- Teachers whose hours differ from the automatic default (Sunday-Thursday 15:00-21:00) clearly chose them already.
update public.teachers t set hours_confirmed_at = now()
 where t.hours_confirmed_at is null
   and exists (select 1 from public.availability a where a.teacher_id = t.id)
   and (select string_agg(a.weekday || ' ' || a.start_time || '-' || a.end_time, ',' order by a.weekday, a.start_time)
          from public.availability a where a.teacher_id = t.id)
       is distinct from '0 15:00:00-21:00:00,1 15:00:00-21:00:00,2 15:00:00-21:00:00,3 15:00:00-21:00:00,4 15:00:00-21:00:00';

-- p_rows: [{"weekday": 0-6 (0 = Sunday), "start": "HH:MM", "end": "HH:MM"}, …]; p_buffer: break between lessons.
-- Returns the number of saved ranges. Any invalid range raises and nothing changes.
create or replace function public.replace_availability(p_rows jsonb, p_buffer int default 0)
returns int language plpgsql security definer set search_path = public as $$
declare v_teacher uuid := my_teacher_id(); r jsonb; v_n int := 0; v_day int; v_s time; v_e time;
        v_names text[] := array['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'];
begin
  if v_teacher is null then raise exception 'هذه الصفحة للمعلمين'; end if;
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 28 then
    raise exception 'بيانات الأوقات غير صالحة';
  end if;
  if coalesce(p_buffer, 0) not in (0, 5, 10, 15, 30) then raise exception 'مدة الاستراحة غير صالحة'; end if;
  create temp table if not exists _hours (weekday int, start_time time, end_time time) on commit drop;
  delete from _hours;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_day := (r->>'weekday')::int;
    if v_day is null or v_day not between 0 and 6 then raise exception 'يوم غير صالح'; end if;
    if coalesce(r->>'start', '') !~ '^([01]\d|2[0-3]):[0-5]\d$' or coalesce(r->>'end', '') !~ '^([01]\d|2[0-3]):[0-5]\d$' then
      raise exception 'في يوم %: اكتب الوقت بصيغة 00:00', v_names[v_day + 1];
    end if;
    v_s := (r->>'start')::time; v_e := (r->>'end')::time;
    if v_e <= v_s then raise exception 'في يوم %: ساعة النهاية يجب أن تكون بعد البداية.', v_names[v_day + 1]; end if;
    if exists (select 1 from _hours h where h.weekday = v_day and h.start_time < v_e and v_s < h.end_time) then
      raise exception 'في يوم %: الفترتان متداخلتان.', v_names[v_day + 1];
    end if;
    insert into _hours values (v_day, v_s, v_e);
    v_n := v_n + 1;
  end loop;
  -- One transaction: if anything below fails, the old hours stay.
  update teachers set buffer_minutes = coalesce(p_buffer, 0), hours_confirmed_at = now() where id = v_teacher;
  delete from availability where teacher_id = v_teacher;
  insert into availability (teacher_id, weekday, start_time, end_time) select v_teacher, weekday, start_time, end_time from _hours;
  if v_n > 0 then perform waitlist_hours_opened(); end if;
  return v_n;
end $$;

------------------------------------------------------------------------------------------------------------
-- BUG-05: a child with upcoming lessons, an active package or a weekly series cannot be removed
-- (their bookings would silently become the parent's). Account deletion is not affected: it cancels the
-- future lessons first, and once the parent's profile is gone the children follow.
------------------------------------------------------------------------------------------------------------
create or replace function public.children_guard_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from profiles where id = old.guardian_id) then return old; end if;   -- account being deleted
  if coalesce(current_setting('classi.bypass_active', true), '') = 'on' then return old; end if;
  if exists (select 1 from lesson_packages p where p.child_id = old.id and p.status = 'active') then
    raise exception 'لـ% رزمة حصص فعّالة. اطلب من المعلم إلغاء الرزمة أو إنهاءها أولاً، ثم احذف الاسم.', old.name;
  end if;
  if exists (
       select 1 from bookings b left join sessions s on s.id = b.session_id
        where b.child_id = old.id and b.status in ('pending','confirmed')
          and (coalesce(b.starts_at, s.starts_at) > now()
               or (b.starts_at is null and b.session_id is null
                   and exists (select 1 from sessions x where x.offering_id = b.offering_id and not x.cancelled and x.starts_at > now()))))
     or exists (select 1 from recurring_series r where r.child_id = old.id and r.status <> 'cancelled') then
    raise exception 'لـ% حصص قادمة أو موعد أسبوعي. ألغِها أولاً من جدولك، ثم احذف الاسم.', old.name;
  end if;
  return old;
end $$;
drop trigger if exists children_guard_delete on public.children;
create trigger children_guard_delete before delete on public.children for each row execute function children_guard_delete();

------------------------------------------------------------------------------------------------------------
-- BUG-02: private lessons can be booked for later today; the database keeps the 2-hour notice that the
-- slot picker already applies (setting: min_lead_minutes).
------------------------------------------------------------------------------------------------------------
create or replace function public.bookings_zzz_lead_time() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_type offering_type;
begin
  if auth.uid() is null or new.booked_by is distinct from auth.uid() or new.starts_at is null then return new; end if;
  -- weekly series: only the first lesson needs the notice (the later weeks are days away by definition)
  if new.series_id is not null and exists (select 1 from bookings b where b.series_id = new.series_id) then return new; end if;
  select type into v_type from offerings where id = new.offering_id;
  if v_type <> 'private' or is_offering_owner(new.offering_id) or is_admin() then return new; end if;
  if new.starts_at < now() + make_interval(mins => coalesce(nullif(setting('min_lead_minutes'), '')::int, 120)) then
    raise exception 'يمكن الحجز قبل ساعتين على الأقل من موعد الحصة';
  end if;
  return new;
end $$;
drop trigger if exists bookings_zzz_lead_time on public.bookings;
create trigger bookings_zzz_lead_time before insert on public.bookings for each row execute function bookings_zzz_lead_time();

------------------------------------------------------------------------------------------------------------
-- Rollback support for phase 1: the teacher-hours booking rule can be lifted alone with a setting
-- (app_settings rule_teacher_hours = 'off'), instead of dropping the whole bookings_zzz_rules trigger.
-- Same function as in 20261031000000_production_hardening.sql plus that one switch.
------------------------------------------------------------------------------------------------------------
create or replace function public.bookings_zzz_rules() returns trigger
language plpgsql security definer set search_path = public as $$
declare o offerings%rowtype; v_local timestamp; v_end timestamp; v_n int;
begin
  -- Only bookings a student makes for themselves; teachers, institutes, walk-ins and scheduled jobs are not limited here.
  if auth.uid() is null or new.booked_by is distinct from auth.uid() then return new; end if;
  select * into o from offerings where id = new.offering_id;
  if is_offering_owner(o.id) or is_admin() then return new; end if;

  if new.pay_method is null or new.pay_method not in ('bit','cash','card','installments','package') then
    raise exception 'طريقة دفع غير معروفة';
  end if;
  if new.pay_method = 'package' and new.package_id is null then
    if new.series_id is not null then
      -- weekly series: the weeks after the package runs out are paid normally (as before), not labelled "package"
      new.pay_method := 'cash';
    else
      raise exception 'لا توجد رزمة فعّالة لهذا الطالب مع هذا العرض';
    end if;
  end if;

  if o.type = 'private' and new.starts_at is not null then
    if o.teacher_id is not null and coalesce(setting('rule_teacher_hours'), 'on') <> 'off' then
      -- inside the teacher's published hours (Israel time); rollback-only switch: app_settings rule_teacher_hours = 'off'

      v_local := new.starts_at at time zone 'Asia/Jerusalem';
      v_end := v_local + make_interval(mins => coalesce(new.minutes, o.minutes));
      if not exists (select 1 from availability a
                      where a.teacher_id = o.teacher_id and a.weekday = extract(dow from v_local)::int
                        and a.start_time <= v_local::time and v_end::date = v_local::date and v_end::time <= a.end_time) then
        raise exception 'هذا الموعد خارج ساعات المعلم المتاحة';
      end if;
    else
      -- private lessons of an institute: one booking per time slot of that offer
      perform pg_advisory_xact_lock(hashtext('offering:' || o.id::text));
      if exists (select 1 from bookings b where b.offering_id = o.id and b.status in ('pending','confirmed') and b.starts_at is not null
                   and tstzrange(b.starts_at, b.starts_at + make_interval(mins => b.minutes))
                    && tstzrange(new.starts_at, new.starts_at + make_interval(mins => coalesce(new.minutes, o.minutes)))) then
        raise exception 'الموعد لم يعد متاحاً، اختر موعداً آخر';
      end if;
    end if;
    if new.series_id is null then
      select count(*) into v_n from bookings b where b.offering_id = o.id and b.booked_by = auth.uid()
         and b.status in ('pending','confirmed') and b.series_id is null and b.starts_at > now();
      if v_n >= coalesce(nullif(setting('max_open_bookings_per_offer'), '')::int, 8) then
        raise exception 'لديك حجوزات قادمة كثيرة مع هذا العرض. للمواعيد الثابتة استخدم الحجز الأسبوعي.';
      end if;
    end if;
  elsif o.type = 'group' and new.session_id is not null then
    if exists (select 1 from bookings b where b.session_id = new.session_id and b.booked_by = auth.uid()
                 and b.child_id is not distinct from new.child_id and b.status in ('pending','confirmed')) then
      raise exception 'هذا الطالب مسجّل في هذا اللقاء';
    end if;
  elsif o.type in ('course','recorded') then
    if exists (select 1 from bookings b where b.offering_id = o.id and b.session_id is null and b.booked_by = auth.uid()
                 and b.child_id is not distinct from new.child_id and b.status in ('pending','confirmed')) then
      raise exception 'هذا الطالب مسجّل في هذا العرض';
    end if;
  end if;
  return new;
end $$;

------------------------------------------------------------------------------------------------------------
-- BUG-26: the institute's attendance register and the teacher's lesson report stay in step both ways
-- (report -> register already existed in write_lesson_report; this adds register -> report).
------------------------------------------------------------------------------------------------------------
create or replace function public.attendance_to_report() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;   -- the change came from a report: nothing to copy back
  update lesson_reports set present = new.present, updated_at = now()
   where booking_id = new.booking_id and session_id = new.session_id and present is distinct from new.present;
  return null;
end $$;
drop trigger if exists attendance_to_report on public.attendance;
create trigger attendance_to_report after insert or update of present on public.attendance
  for each row execute function attendance_to_report();

------------------------------------------------------------------------------------------------------------
-- Least privilege (phase 1): new trigger functions are not callable; the new RPC is granted explicitly.
------------------------------------------------------------------------------------------------------------
revoke execute on function public.replace_availability(jsonb, int), public.children_guard_delete(), public.bookings_zzz_rules(),
  public.bookings_zzz_lead_time(), public.attendance_to_report() from public, anon, authenticated;
grant execute on function public.replace_availability(jsonb, int) to authenticated;
