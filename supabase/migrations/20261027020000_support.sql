-- Classi: support WhatsApp number (the floating "need help?" button), editable by the admin.
create or replace function public.admin_set_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := trim(coalesce(p_value, ''));
begin
  if not is_admin() then raise exception 'هذه الصفحة للمدير فقط'; end if;
  if p_key not in ('subscriptions_required','platform_bit','support_whatsapp') then raise exception 'إعداد غير معروف'; end if;
  if p_key in ('platform_bit','support_whatsapp') and v <> '' then
    v := clean_phone(v);
    if v is null then raise exception 'رقم الجوال غير صحيح'; end if;
  end if;
  if p_key = 'subscriptions_required' and v not in ('true','false') then raise exception 'قيمة غير صالحة'; end if;
  insert into app_settings (key, value, updated_at) values (p_key, v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

-- Start with the admin's number; changeable from the admin panel.
insert into app_settings (key, value, updated_at) values ('support_whatsapp', '+972509318800', now())
on conflict (key) do nothing;
