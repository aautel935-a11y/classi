-- Classi: optional public WhatsApp number for teachers and institutes (shown as a "WhatsApp" button).
alter table public.teachers   add column if not exists whatsapp text check (whatsapp is null or whatsapp ~ '^\+9725[0-9]{8}$');
alter table public.institutes add column if not exists whatsapp text check (whatsapp is null or whatsapp ~ '^\+9725[0-9]{8}$');
