\pset pager off
\pset footer off
insert into auth.users (id, email, raw_user_meta_data) values
 ('40000000-0000-0000-0000-000000000002','samer@t','{"full_name":"سامر"}'),
 ('40000000-0000-0000-0000-000000000003','rana@t','{"full_name":"رنا"}'),
 ('40000000-0000-0000-0000-000000000004','mom@t','{"full_name":"أم يوسف"}'),
 ('40000000-0000-0000-0000-000000000005','dad@t','{"full_name":"أبو آدم"}');
update teachers set user_id='40000000-0000-0000-0000-000000000002' where name='سامر مصاروة';
update teachers set user_id='40000000-0000-0000-0000-000000000003' where name='رنا أبو حسين';
insert into children (id, guardian_id, name) values ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000004','يوسف');
create temp table ids as select
  (select id from offerings where title='رياضيات بجروت 5 وحدات') priv,
  (select id from offerings where title='مجموعة أونلاين، تحضير الشفوي') grp,
  (select id from offerings where title='إنجليزي محادثة للإعدادي') crs;
-- lessons at different distances from now
insert into bookings (offering_id, booked_by, child_id, starts_at, minutes, status, mode) values
 ((select priv from ids), '40000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000001', now() + interval '23 hours 30 minutes', 60, 'confirmed', 'online'),
 ((select priv from ids), '40000000-0000-0000-0000-000000000005', null, now() + interval '40 minutes', 60, 'confirmed', 'home'),
 ((select priv from ids), '40000000-0000-0000-0000-000000000005', null, now() + interval '5 hours', 60, 'confirmed', 'home'),
 ((select priv from ids), '40000000-0000-0000-0000-000000000004', null, now() + interval '30 minutes', 60, 'pending', 'home');
update sessions set starts_at = now() + interval '50 minutes'
 where id = (select id from sessions where offering_id = (select grp from ids) order by starts_at limit 1);
insert into bookings (offering_id, session_id, booked_by, minutes, status, mode)
 select (select grp from ids), id, '40000000-0000-0000-0000-000000000004', 60, 'confirmed', 'online'
   from sessions where offering_id = (select grp from ids) order by starts_at limit 1;
update sessions set starts_at = now() + interval '22 hours'
 where id = (select id from sessions where offering_id = (select crs from ids) and starts_at > now() order by starts_at limit 1);
insert into bookings (offering_id, booked_by, minutes, status, mode) values ((select crs from ids), '40000000-0000-0000-0000-000000000005', 90, 'confirmed', 'center');
delete from notifications;

\echo '===== 1. Reminders due now'
select 'sent' t, send_reminders() n;
select p.full_name who, n.kind, n.body, n.want_push from notifications n join profiles p on p.id = n.user_id order by p.full_name, n.kind;

\echo '===== 2. Running again sends nothing new'
select 'sent again' t, send_reminders() n;

\echo '===== 3. Students cannot run the scheduler'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select send_reminders();
reset role;

\echo '===== 4. Phone subscription + delivery queue'
set role authenticated; set request.jwt.claim.sub='40000000-0000-0000-0000-000000000004';
select save_push_subscription('https://fcm.googleapis.com/fcm/send/abc', 'BPUBKEY', 'AUTHKEY');
select 'own subs' t, count(*) from push_subscriptions;
select 'secrets hidden (expect error)' t;
select * from app_secrets;
reset role;
set role anon;
select 'wrong secret (expect error)' t;
select claim_push('nope');
reset role;
insert into app_secrets values ('dispatch_secret','s3cret'), ('vapid_public','PUB'), ('vapid_private','PRIV');
set role anon;
select 'claim' t, jsonb_array_length(x->'items') items, x->>'vapid_public' pub,
       (select count(*) from jsonb_array_elements(x->'items') e where jsonb_array_length(e->'subs') > 0) with_phone,
       (select string_agg(e->>'email', ',') from jsonb_array_elements(x->'items') e where e->>'email' is not null) emails
  from (select claim_push('s3cret') x) q;
select 'claim again (expect 0)' t, jsonb_array_length(claim_push('s3cret')->'items');
select 'drop dead sub' t, drop_push_subscriptions('s3cret', array['https://fcm.googleapis.com/fcm/send/abc']);
reset role;
select 'subs left' t, count(*) from push_subscriptions;
