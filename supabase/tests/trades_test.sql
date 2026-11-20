-- Trades foundation: professions, provider registration with admin approval, service requests, quotes, isolation.
-- Every check prints PASS:/FAIL:. Synthetic accounts only (ids 7200…). Run: sh supabase/tests/run.sh trades_test
\pset pager off
\pset footer off
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
 ('72000000-0000-0000-0000-00000000000a','pro@t','{"full_name":"كهربائي سامر"}'),
 ('72000000-0000-0000-0000-00000000000b','co@t','{"full_name":"صاحب شركة"}'),
 ('72000000-0000-0000-0000-00000000000c','cust@t','{"full_name":"زبونة"}'),
 ('72000000-0000-0000-0000-00000000000d','cust2@t','{"full_name":"زبون آخر"}'),
 ('72000000-0000-0000-0000-00000000000e','admin2@t','{"full_name":"مدير"}'),
 ('72000000-0000-0000-0000-00000000000f','pro2@t','{"full_name":"سبّاك"}');
update profiles set roles = array['admin']::app_role[] where id = '72000000-0000-0000-0000-00000000000e';
update teachers set user_id='72000000-0000-0000-0000-00000000000a' where name='سامر مصاروة';
update teachers set user_id='72000000-0000-0000-0000-00000000000f' where name='نور كبها';
update institutes set owner_id='72000000-0000-0000-0000-00000000000b' where name='معهد المستقبل';
create temp table ids as select
  (select id from teachers where name='سامر مصاروة') pro,
  (select id from teachers where name='نور كبها') pro2,
  (select id from institutes where name='معهد المستقبل') co,
  (select id from professions where slug='electrician') elec,
  (select id from professions where slug='plumber') plumb;
grant select on ids to authenticated, anon;
create temp table v (k text primary key, id uuid);
grant all on v to authenticated;
create temp table edu_before as select
  (select md5(string_agg(t::text, ',' order by t.id)) from teachers t) teachers,
  (select md5(string_agg(i::text, ',' order by i.id)) from institutes i) institutes,
  (select count(*) from offerings) offerings, (select count(*) from search_offers()) visible;

\echo '===== no direct table access; visitors see only the professions list'
set role anon; set request.jwt.claim.sub='';
select t_is('anon: professions list', $$select count(*)::text from list_professions()$$, '8');
select t_err('anon cannot read requests', $$select count(*) from service_requests$$);
select t_err('anon cannot create a request', $$select create_service_request((select elec from ids), 'باقة', 'انقطاع كهرباء في المطبخ')$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_err('authenticated cannot read quotes', $$select count(*) from quotes$$);
select t_err('authenticated cannot insert a request directly', $$insert into service_requests (customer_id, profession_id, town, description) values (auth.uid(), 1, 'باقة', 'xxxxxxxxxxxx')$$);
select t_err('helpers are not callable', $$select trades_matches(null, null, null)$$);
reset role;

\echo '===== provider registration needs admin approval'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000a';
select t_ok('electrician registers for two towns', $$insert into v select 'reg', register_profession((select pro from ids), null, (select elec from ids), array['  باقة الغربية ', 'جت'])$$);
select t_is('towns are normalized', $$select array_to_string(towns, '|') from my_professions((select pro from ids), null)$$, 'باقة الغربية|جت');
select t_is('not approved yet', $$select approved::text from my_professions((select pro from ids), null)$$, 'false');
select t_err('cannot register for someone else''s business', $$select register_profession((select pro2 from ids), null, (select elec from ids))$$);
select t_err('cannot approve itself', $$select admin_review_profession((select id from v where k='reg'), true)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000b';
select t_ok('company registers as plumber everywhere', $$insert into v select 'reg2', register_profession(null, (select co from ids), (select plumb from ids))$$);
reset role;

\echo '===== customer request'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_err('too short description', $$select create_service_request((select elec from ids), 'باقة الغربية', 'قصير')$$);
select t_err('unknown profession', $$select create_service_request(999::smallint, 'باقة الغربية', 'وصف كافٍ للعمل المطلوب')$$);
select t_ok('request: electrician in Baqa', $$insert into v select 'r1', create_service_request((select elec from ids), 'باقة  الغربية', 'انقطاع الكهرباء في المطبخ بعد تبديل المصباح', 'هذا الأسبوع صباحاً')$$);
select t_is('town normalized on the request', $$select town from my_service_requests() where id = (select id from v where k='r1')$$, 'باقة الغربية');
select t_is('status open, 0 quotes', $$select status || ':' || quotes from my_service_requests() where id = (select id from v where k='r1')$$, 'open:0');
reset role;

\echo '===== before approval the electrician sees nothing and cannot quote'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000a';
select t_is('no matching requests before approval', $$select count(*)::text from open_requests_for((select pro from ids), null)$$, '0');
select t_err('no quote before approval', $$select send_quote((select id from v where k='r1'), (select pro from ids), null, 200, 300, 'فحص وتبديل القاطع', current_date + 7)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000e';
select t_is('admin queue shows both registrations', $$select count(*)::text from admin_profession_queue()$$, '2');
select t_ok('admin approves the electrician', $$select admin_review_profession((select id from v where k='reg'), true)$$);
select t_ok('admin approves the plumbing company', $$select admin_review_profession((select id from v where k='reg2'), true)$$);
reset role;

\echo '===== matching: profession and town; no customer identity'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000a';
select t_is('the electrician sees the Baqa request', $$select count(*)::text from open_requests_for((select pro from ids), null) where id = (select id from v where k='r1')$$, '1');
select t_is('the row carries no customer name or phone', $$select (row_to_json(x)::text ~ 'زبونة|cust@t|72000000-0000-0000-0000-00000000000c')::text from open_requests_for((select pro from ids), null) x limit 1$$, 'false');
select t_err('invalid price range', $$select send_quote((select id from v where k='r1'), (select pro from ids), null, 300, 200, 'فحص', current_date + 7)$$);
select t_err('validity in the past', $$select send_quote((select id from v where k='r1'), (select pro from ids), null, 200, 300, 'فحص', current_date - 1)$$);
select t_ok('quote 200-300', $$insert into v select 'q1', send_quote((select id from v where k='r1'), (select pro from ids), null, 200, 300, 'فحص وتبديل القاطع والأسلاك', current_date + 7)$$);
select t_ok('update the same quote (one per provider)', $$select send_quote((select id from v where k='r1'), (select pro from ids), null, 220, 280, 'فحص وتبديل القاطع والأسلاك', current_date + 7)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000b';
select t_is('the plumbing company does not see an electrician request', $$select count(*)::text from open_requests_for(null, (select co from ids))$$, '0');
select t_err('and cannot quote on it', $$select send_quote((select id from v where k='r1'), null, (select co from ids), 100, 100, 'سباكة', current_date + 3)$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_ok('second request: plumber in Jat', $$insert into v select 'r2', create_service_request((select plumb from ids), 'جت', 'تسريب مياه تحت المغسلة في الحمام')$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000a';
select t_is('the electrician (Baqa, Jat) does not see a plumbing request', $$select count(*)::text from open_requests_for((select pro from ids), null) where id = (select id from v where k='r2')$$, '0');
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000b';
select t_is('the plumbing company (every town) sees the Jat request', $$select count(*)::text from open_requests_for(null, (select co from ids)) where id = (select id from v where k='r2')$$, '1');
select t_ok('company quotes', $$insert into v select 'q2', send_quote((select id from v where k='r2'), null, (select co from ids), 150, 150, 'تبديل الوصلة', current_date + 5, now() + interval '2 days')$$);
reset role;

\echo '===== the customer sees and accepts; others see nothing'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000d';
select t_is('another customer sees no requests', $$select count(*)::text from my_service_requests()$$, '0');
select t_is('another customer sees no quotes', $$select count(*)::text from request_quotes((select id from v where k='r1'))$$, '0');
select t_err('another customer cannot accept', $$select accept_quote((select id from v where k='q1'))$$);
select t_err('another customer cannot cancel', $$select cancel_service_request((select id from v where k='r1'))$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_is('request quoted, 1 quote', $$select status || ':' || quotes from my_service_requests() where id = (select id from v where k='r1')$$, 'quoted:1');
select t_is('the quote shows the updated price and provider', $$select price_min || '-' || price_max || ' ' || provider from request_quotes((select id from v where k='r1'))$$, '220.00-280.00 سامر مصاروة');
select t_ok('accept the quote', $$select accept_quote((select id from v where k='q1'))$$);
select t_is('request accepted', $$select status from my_service_requests() where id = (select id from v where k='r1')$$, 'accepted');
select t_err('cannot accept twice', $$select accept_quote((select id from v where k='q1'))$$);
select t_err('cannot cancel an accepted request', $$select cancel_service_request((select id from v where k='r1'))$$);
reset role;
select t_is('the provider was notified', $$select count(*)::text from notifications where user_id = '72000000-0000-0000-0000-00000000000a' and kind = 'quote_accepted'$$, '1');
select t_is('the customer was notified of quotes', $$select count(*)::text from notifications where user_id = '72000000-0000-0000-0000-00000000000c' and kind = 'quote_new'$$, '3');
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000a';
select t_err('no new quote on an accepted request', $$select send_quote((select id from v where k='r1'), (select pro from ids), null, 100, 100, 'x x x', current_date + 2)$$);
select t_is('an accepted request leaves the provider list', $$select count(*)::text from open_requests_for((select pro from ids), null) where id = (select id from v where k='r1')$$, '0');
reset role;

\echo '===== withdraw, cancel, limits, expiry'
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000b';
select t_ok('company withdraws its quote', $$select withdraw_quote((select id from v where k='q2'))$$);
select t_err('cannot withdraw twice', $$select withdraw_quote((select id from v where k='q2'))$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000a';
select t_err('someone else cannot withdraw the company quote', $$select withdraw_quote((select id from v where k='q2'))$$);
reset role;
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000c';
select t_is('withdrawn quotes are not shown to the customer', $$select count(*)::text from request_quotes((select id from v where k='r2'))$$, '0');
select t_ok('customer cancels the plumbing request', $$select cancel_service_request((select id from v where k='r2'))$$);
select t_ok('four more requests (5 open)', $$select create_service_request((select elec from ids), 'جت', 'طلب رقم ' || g || ' للتجربة فقط') from generate_series(1, 5) g$$);
select t_err('a sixth open request is refused', $$select create_service_request((select elec from ids), 'جت', 'طلب سادس للتجربة فقط')$$);
reset role;
update service_requests set expires_at = now() - interval '1 minute' where customer_id = '72000000-0000-0000-0000-00000000000c' and status = 'open';
select t_is('expiry job closes old requests', $$select expire_service_requests()::text$$, '5');
set role authenticated; set request.jwt.claim.sub='72000000-0000-0000-0000-00000000000a';
select t_is('expired requests are not offered', $$select count(*)::text from open_requests_for((select pro from ids), null)$$, '0');
select t_err('expiry job is not callable by users', $$select expire_service_requests()$$);
reset role;

\echo '===== education untouched'
select t_is('teachers and institutes rows unchanged', $$select (md5(string_agg(t::text, ',' order by t.id)) = (select teachers from edu_before))::text from teachers t$$, 'true');
select t_is('institutes unchanged', $$select (md5(string_agg(i::text, ',' order by i.id)) = (select institutes from edu_before))::text from institutes i$$, 'true');
select t_is('offerings and the public search unchanged', $$select ((select count(*) from offerings) = offerings and (select count(*) from search_offers()) = visible)::text from edu_before$$, 'true');
select t_is('RLS on every new table', $$select count(*)::text from pg_class where relname in ('professions','provider_professions','service_requests','quotes') and relrowsecurity$$, '4');
