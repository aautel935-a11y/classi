-- Rollback of 20261103010000_review_columns_owner_only.sql: signed-in users can read every column again
-- (the state before; anon stays limited as set by SEC-06). No data to restore.
-- my_review_state() is deliberately KEPT: it only returns the caller's own rows, and the app version that uses it keeps
-- working after this rollback. Drop it only together with that app version:
--   drop function if exists public.my_review_state();
-- On a hosted project, also remove the migration record afterwards (Supabase -> SQL editor):
--   delete from supabase_migrations.schema_migrations where version = '20261103010000';
begin;
grant select on public.teachers, public.institutes, public.offerings to authenticated;
commit;
