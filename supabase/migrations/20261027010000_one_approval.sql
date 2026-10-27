-- Classi: one approval is enough.
-- Before: an offer was visible only if the offer was approved (review tab) AND its owner was verified (verify tab),
-- and new profiles never showed in the review tab, so an approved offer could stay invisible.
-- Now: new teacher / institute profiles show in the review queue; approving the profile, or its first offer, makes it visible.
create or replace function public.admin_review_queue()
returns table (kind text, id uuid, owner_name text, title text, what text, current jsonb, changes jsonb, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select 'offering', o.id, coalesce(t.name, i.name), o.title,
         case when o.review_status = 'pending' then 'new' else 'edit' end,
         jsonb_build_object('title', o.title, 'type', o.type, 'price', o.price, 'subject', s.name, 'level', l.name, 'places', o.places,
                            'schedule_note', o.schedule_note, 'trial_price', o.trial_price, 'package_enabled', o.package_enabled,
                            'package_size', o.package_size, 'package_price', o.package_price),
         o.pending_changes, o.created_at
    from offerings o left join teachers t on t.id = o.teacher_id left join institutes i on i.id = o.institute_id
    left join subjects s on s.id = o.subject_id left join levels l on l.id = o.level_id
   where is_admin() and (o.review_status = 'pending' or o.pending_changes is not null)
  union all
  select 'teacher', t.id, t.name, t.name, case when t.verify = 'pending' then 'new' else 'edit' end,
         jsonb_build_object('name', t.name, 'bio', t.bio, 'photo_url', t.photo_url, 'intro_video_url', t.intro_video_url, 'town', t.town, 'years', t.years),
         t.pending_changes, t.created_at
    from teachers t where is_admin() and (t.pending_changes is not null or (t.verify = 'pending' and t.user_id is not null))
  union all
  select 'institute', i.id, i.name, i.name, case when i.verify = 'pending' then 'new' else 'edit' end,
         jsonb_build_object('name', i.name, 'bio', i.bio, 'logo_url', i.logo_url, 'town', i.town),
         i.pending_changes, i.created_at
    from institutes i where is_admin() and (i.pending_changes is not null or (i.verify = 'pending' and i.owner_id is not null))
  order by 8
$$;

create or replace function public.admin_review(p_kind text, p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_title text; v_changes jsonb; v_new boolean; v_note text := nullif(trim(p_note), '');
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_kind = 'offering' then
    select offering_owner_user(id), title, pending_changes, review_status <> 'approved' into v_owner, v_title, v_changes, v_new from offerings where id = p_id;
    if v_title is null then raise exception 'العرض غير موجود'; end if;
    if v_new then
      update offerings set review_status = case when p_approve then 'approved' else 'rejected' end, review_note = v_note, pending_changes = null where id = p_id;
      -- One approval is enough: a new teacher's / institute's first approved offer also approves their profile.
      if p_approve then
        update teachers set verify = 'verified' where verify = 'pending' and id = (select teacher_id from offerings where id = p_id);
        update institutes set verify = 'verified' where verify = 'pending' and id = (select institute_id from offerings where id = p_id);
      end if;
    elsif p_approve then
      update offerings set (title, subject_id, level_id, places, schedule_note, lessons_count, sessions_count, trial_price, package_enabled, package_size, package_price, minutes) =
        (select x.title, x.subject_id, x.level_id, x.places, x.schedule_note, x.lessons_count, x.sessions_count, x.trial_price, x.package_enabled, x.package_size, x.package_price, x.minutes
           from jsonb_populate_record(offerings, coalesce(v_changes, '{}'::jsonb)) x),
        pending_changes = null, review_note = v_note
       where id = p_id;
    else
      update offerings set pending_changes = null, review_note = v_note where id = p_id;
    end if;
    insert into notifications (user_id, kind, body, link)
    select v_owner, 'review_answer',
           case when p_approve then format('تمت الموافقة على %s: %s. %s', case when v_new then 'عرضك' else 'تعديلك على' end, v_title,
                                           case when v_new then 'العرض ظاهر الآن للطلاب.' else 'التعديل ظاهر الآن.' end)
                else format('لم تتم الموافقة على %s: %s.%s', case when v_new then 'عرضك' else 'تعديلك على' end, v_title, coalesce(' السبب: ' || v_note, '')) end,
           '/manage/course/' || p_id
     where v_owner is not null;
  elsif p_kind in ('teacher','institute') then
    if p_kind = 'teacher' then
      select user_id, name, pending_changes, verify = 'pending' into v_owner, v_title, v_changes, v_new from teachers where id = p_id;
      update teachers set verify = case when p_approve then 'verified' else 'rejected' end::verify_status where id = p_id and verify = 'pending';
      if p_approve then
        update teachers t set (name, bio, photo_url, intro_video_url, subject_id, years, is_school_teacher, town) =
          (select x.name, x.bio, x.photo_url, x.intro_video_url, x.subject_id, x.years, x.is_school_teacher, x.town
             from jsonb_populate_record(t, coalesce(v_changes, '{}'::jsonb)) x),
          pending_changes = null, review_note = v_note where t.id = p_id;
      else
        update teachers set pending_changes = null, review_note = v_note where id = p_id;
      end if;
    else
      select owner_id, name, pending_changes, verify = 'pending' into v_owner, v_title, v_changes, v_new from institutes where id = p_id;
      update institutes set verify = case when p_approve then 'verified' else 'rejected' end::verify_status where id = p_id and verify = 'pending';
      if p_approve then
        update institutes i set (name, bio, logo_url, town) =
          (select x.name, x.bio, x.logo_url, x.town from jsonb_populate_record(i, coalesce(v_changes, '{}'::jsonb)) x),
          pending_changes = null, review_note = v_note where i.id = p_id;
      else
        update institutes set pending_changes = null, review_note = v_note where id = p_id;
      end if;
    end if;
    insert into notifications (user_id, kind, body, link)
    select v_owner, 'review_answer',
           case when p_approve and v_new then 'تمت الموافقة على ملفك، وهو ظاهر الآن للطلاب مع عروضك الموافق عليها.'
                when p_approve then 'تمت الموافقة على تعديلات ملفك، وهي ظاهرة الآن.'
                when v_new then format('لم تتم الموافقة على ملفك.%s', coalesce(' السبب: ' || v_note, ''))
                else format('لم تتم الموافقة على تعديلات ملفك.%s', coalesce(' السبب: ' || v_note, '')) end,
           case when p_kind = 'teacher' then '/teach' else '/manage' end
     where v_owner is not null;
  else
    raise exception 'نوع غير معروف';
  end if;
  insert into moderation_actions (admin_id, target_type, target_id, action, reason)
  values (auth.uid(), p_kind, p_id, case when p_approve then 'review_approve' else 'review_reject' end, v_note);
end $$;

revoke execute on function public.admin_review_queue, public.admin_review from anon, public;
grant execute on function public.admin_review_queue, public.admin_review to authenticated;
