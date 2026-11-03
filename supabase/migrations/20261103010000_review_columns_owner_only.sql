-- Phase 6: unapproved edits and moderation notes are visible only to their owner and to admins.
-- Before: visitors (anon) could not read pending_changes / review_note (SEC-06), but every signed-in user could read
-- them for every teacher, institute and offer. Now:
--   * anon and authenticated: every column of teachers / institutes / offerings EXCEPT pending_changes and review_note
--   * the owner: public.my_review_state() returns the pending changes and notes of their own teacher profile,
--     institute and offers (teacher's own offers, and an institute owner's offers)
--   * admins: unchanged, through admin_review_queue() / admin_review() (security definer)
--   * triggers and security-definer functions (content review, admin_review) are not affected by column grants
-- Column grants are computed from the current columns. A column added later to these tables must be granted to
-- anon and authenticated explicitly (supabase/tests/review_access_test.sql fails until it is).
-- Rollback: supabase/rollback/20261103010000_review_columns_owner_only.down.sql
-- Safe on a live database: privileges and one function, no data change.

do $$
declare r record; v_cols text;
begin
  for r in select unnest(array['teachers', 'institutes', 'offerings']) as tbl loop
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
      from information_schema.columns
     where table_schema = 'public' and table_name = r.tbl and column_name not in ('pending_changes', 'review_note');
    execute format('revoke select on public.%I from authenticated', r.tbl);
    execute format('grant select (%s) on public.%I to authenticated', v_cols, r.tbl);
  end loop;
end $$;

create or replace function public.my_review_state()
returns table (kind text, id uuid, pending_changes jsonb, review_note text)
language sql stable security definer set search_path = public as $$
  select 'teacher'::text, t.id, t.pending_changes, t.review_note from teachers t where t.user_id = auth.uid()
  union all
  select 'institute'::text, i.id, i.pending_changes, i.review_note from institutes i where i.owner_id = auth.uid()
  union all
  select 'offering'::text, o.id, o.pending_changes, o.review_note
    from offerings o
    left join teachers t on t.id = o.teacher_id
    left join institutes i on i.id = o.institute_id
   where auth.uid() is not null and (t.user_id = auth.uid() or i.owner_id = auth.uid())
$$;
revoke execute on function public.my_review_state() from public, anon;
grant execute on function public.my_review_state() to authenticated;
