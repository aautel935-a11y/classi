-- Undo 20261031010000_functional_fixes.sql. Roll the APP back first (it calls replace_availability).
-- Keeps: teachers.hours_confirmed_at (unused by the old app, harmless). Nothing else depends on these objects.
drop trigger if exists children_guard_delete on public.children;
drop trigger if exists bookings_zzz_lead_time on public.bookings;
drop trigger if exists attendance_to_report on public.attendance;
drop function if exists public.children_guard_delete();
drop function if exists public.bookings_zzz_lead_time();
drop function if exists public.attendance_to_report();
drop function if exists public.replace_availability(jsonb, int);
