grant select, insert, update, delete on all tables in schema public to anon, authenticated;
grant usage, select on all sequences in schema public to anon, authenticated;

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
