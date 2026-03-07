-- ═══════════════════════════════════════════════════════
--  AI PropHunt — Supabase Schema
--  Ejecutar en Supabase SQL Editor
-- ═══════════════════════════════════════════════════════

-- Tabla de contactos (reemplaza contacted.json)
create table contacts (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) not null,
  phone text not null,
  name text,
  url text,
  property_code text,
  portal text,
  zone text,
  price numeric,
  property_type text,
  detail text,
  status text default 'sent',
  message_preview text,
  date_contacted timestamptz default now(),
  created_at timestamptz default now()
);

-- Tabla de logs (reemplaza data/logs/*.log)
create table logs (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) not null,
  message text not null,
  level text default 'info',
  created_at timestamptz default now()
);

-- Tabla de config (reemplaza config.json)
create table configs (
  user_id uuid references auth.users(id) primary key,
  max_contacts_per_day integer default 15,
  min_delay_minutes integer default 2,
  auto_update boolean default true,
  portals jsonb default '["idealista","fotocasa","pisos.com"]',
  schedule jsonb default '{"morning":"09:00-14:00","afternoon":"16:00-20:00"}',
  created_at timestamptz default now()
);

-- RLS: cada usuario solo ve sus datos
alter table contacts enable row level security;
alter table logs enable row level security;
alter table configs enable row level security;

create policy "Users see own contacts" on contacts
  for all using (auth.uid() = user_id);

create policy "Users see own logs" on logs
  for all using (auth.uid() = user_id);

create policy "Users see own config" on configs
  for all using (auth.uid() = user_id);

-- Funcion para verificar si el registro esta abierto (< 1 usuario)
create or replace function is_registration_open()
returns boolean
language sql
security definer
as $$
  select count(*) < 1 from auth.users;
$$;

-- Indices para queries frecuentes
create index idx_contacts_user_date on contacts(user_id, date_contacted desc);
create index idx_contacts_phone on contacts(phone);
create index idx_contacts_url on contacts(url);
create index idx_logs_user_date on logs(user_id, created_at desc);
