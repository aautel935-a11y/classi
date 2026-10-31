-- Table privileges come from Supabase's default privileges (mirrored in supabase_stub.sql) and from the
-- migrations themselves; nothing is granted here, so tests see exactly what production sees.

-- Test helper: an admin approves everything waiting for review.
create or replace function public.test_approve_all() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  update offerings o set
    title = coalesce(x.title, o.title), subject_id = x.subject_id, level_id = x.level_id, places = x.places,
    schedule_note = x.schedule_note, trial_price = x.trial_price, package_enabled = x.package_enabled,
    package_size = x.package_size, package_price = x.package_price, pending_changes = null
  from offerings src, jsonb_populate_record(src, coalesce(src.pending_changes, '{}'::jsonb)) x
  where src.id = o.id and o.pending_changes is not null;
  update offerings set review_status = 'approved' where review_status <> 'approved';
  update teachers t set bio = x.bio, photo_url = x.photo_url, intro_video_url = x.intro_video_url, name = x.name, pending_changes = null
  from teachers src, jsonb_populate_record(src, src.pending_changes) x where src.id = t.id and t.pending_changes is not null;
end $$;

-- Test helper: the next given weekday (0 = Sunday) at least p_min days from today, so suites do not depend
-- on the day they run (seed groups meet on fixed weekdays; teachers' default hours are Sunday to Thursday).
create or replace function public.test_day(p_dow int, p_min int default 2) returns date language sql stable as $$
  select d::date from generate_series(current_date + p_min, current_date + p_min + 6, interval '1 day') d
   where extract(dow from d)::int = p_dow limit 1
$$;
grant execute on function public.test_day(int, int) to anon, authenticated;

-- ---------- assertion helpers (run with the caller's role) ----------
create or replace function public.t_ok(p_label text, p_sql text) returns void language plpgsql as $$
begin execute p_sql; raise notice 'PASS: %', p_label;
exception when others then raise notice 'FAIL: % -> %', p_label, sqlerrm; end $$;
create or replace function public.t_err(p_label text, p_sql text) returns void language plpgsql as $$
begin execute p_sql; raise notice 'FAIL: % -> it was allowed', p_label;
exception when others then raise notice 'PASS: % (refused: %)', p_label, left(sqlerrm, 90); end $$;
create or replace function public.t_is(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
declare v text;
begin execute p_sql into v;
  if v is not distinct from p_expect then raise notice 'PASS: % = %', p_label, coalesce(v, 'null');
  else raise notice 'FAIL: % -> got %, expected %', p_label, coalesce(v, 'null'), coalesce(p_expect, 'null'); end if;
exception when others then raise notice 'FAIL: % -> %', p_label, sqlerrm; end $$;
grant execute on function public.t_ok(text,text), public.t_err(text,text), public.t_is(text,text,text) to anon, authenticated;

