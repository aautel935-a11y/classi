-- Rollback of 20261121000000_trades_foundation.sql: removes the trades tables and functions. Requests, quotes and
-- provider registrations are DELETED with their tables (the foundation has no production data).
begin;
drop function if exists public.expire_service_requests(), public.withdraw_quote(uuid),
  public.send_quote(uuid, uuid, uuid, numeric, numeric, text, date, timestamptz), public.open_requests_for(uuid, uuid),
  public.accept_quote(uuid), public.request_quotes(uuid), public.my_service_requests(), public.cancel_service_request(uuid),
  public.create_service_request(smallint, text, text, text), public.admin_review_profession(uuid, boolean),
  public.admin_profession_queue(), public.my_professions(uuid, uuid), public.register_profession(uuid, uuid, smallint, text[]),
  public.list_professions(), public.trades_owner_user(uuid, uuid), public.trades_matches(uuid, uuid, uuid),
  public.trades_is_owner(uuid, uuid), public.trades_town(text);
drop table if exists public.quotes, public.service_requests, public.provider_professions, public.professions cascade;
commit;
