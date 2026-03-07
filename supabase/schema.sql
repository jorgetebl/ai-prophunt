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

-- Tokens de instalacion (vincula Mac con cuenta)
create table setup_tokens (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) not null,
  token text not null unique,
  used boolean default false,
  expires_at timestamptz not null,
  created_at timestamptz default now()
);

alter table setup_tokens enable row level security;

create policy "Users manage own tokens" on setup_tokens
  for all using (auth.uid() = user_id);

-- RPC: Generar token de instalacion (solo usuarios autenticados)
create or replace function create_setup_token()
returns text
language plpgsql
security definer
as $$
declare
  new_token text;
begin
  new_token := upper(substr(md5(random()::text), 1, 8));
  update setup_tokens set used = true where user_id = auth.uid() and used = false;
  insert into setup_tokens (user_id, token, expires_at)
  values (auth.uid(), new_token, now() + interval '1 hour');
  return new_token;
end;
$$;

-- RPC: Validar token de instalacion (callable con anon key)
create or replace function validate_setup_token(setup_token text)
returns json
language plpgsql
security definer
as $$
declare
  token_record record;
begin
  select st.*, u.email into token_record
  from setup_tokens st
  join auth.users u on u.id = st.user_id
  where st.token = upper(setup_token)
    and st.used = false
    and st.expires_at > now();

  if not found then
    return json_build_object('valid', false, 'error', 'Token invalido o expirado');
  end if;

  update setup_tokens set used = true where id = token_record.id;

  return json_build_object(
    'valid', true,
    'user_id', token_record.user_id,
    'email', token_record.email
  );
end;
$$;

-- Indices para queries frecuentes
create index idx_contacts_user_date on contacts(user_id, date_contacted desc);
create index idx_contacts_phone on contacts(phone);
create index idx_contacts_url on contacts(url);
create index idx_logs_user_date on logs(user_id, created_at desc);
