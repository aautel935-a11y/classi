-- Classi: profile photos and the admin role.

-- ---------- photos ----------
alter table public.teachers   add column if not exists photo_url text;
alter table public.institutes add column if not exists logo_url text;
alter table public.profiles   add column if not exists avatar_url text;

-- Public bucket; each account writes only inside its own folder: avatars/<user id>/...
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 2097152,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];

create policy "avatars: read" on storage.objects for select
  using (bucket_id = 'avatars');
create policy "avatars: upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars: replace own" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- admin ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and 'admin' = any(roles))
$$;

create policy "admin reads teachers"   on public.teachers   for select using (is_admin());
create policy "admin reads institutes" on public.institutes for select using (is_admin());

-- Approve or reject a teacher or institute; tells its owner.
create or replace function public.admin_verify(p_kind text, p_id uuid, p_status public.verify_status)
returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_name text;
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_kind = 'teacher' then
    update teachers set verify = p_status where id = p_id returning user_id, name into v_user, v_name;
  elsif p_kind = 'institute' then
    update institutes set verify = p_status where id = p_id returning owner_id, name into v_user, v_name;
  else
    raise exception 'نوع غير معروف';
  end if;
  if v_user is not null then
    insert into notifications (user_id, kind, body, link) values (
      v_user, 'verify',
      case when p_status = 'verified' then format('تم توثيق %s. ملفك وعروضك تظهر الآن للطلاب.', v_name)
           else format('لم يتم توثيق %s بعد. راسلنا لاستكمال الوثائق.', v_name) end,
      case when p_kind = 'teacher' then '/teach' else '/manage' end);
  end if;
end $$;

revoke execute on function public.admin_verify from anon, public;
grant execute on function public.admin_verify, public.is_admin to authenticated;
