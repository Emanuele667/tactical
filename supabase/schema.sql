-- TACTICAL AI - MIGRAZIONE BACKEND COMPLETA E RIPETIBILE
-- Eseguire in Supabase > SQL Editor > New query.
-- Non elimina partite, giocatori, obiettivi o eventi esistenti.

create extension if not exists pgcrypto;

-- 1) Tabelle
create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  game_code text not null unique,
  name text not null,
  mode text not null default 'MilSim',
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.game_members (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  player_name text not null,
  team text not null default 'ALFA' check (team in ('ALFA','BRAVO','ORGANIZZATORE')),
  lat double precision,
  lng double precision,
  location_updated_at timestamptz,
  joined_at timestamptz not null default now(),
  unique (game_id, user_id),
  check ((lat is null and lng is null) or (lat between -90 and 90 and lng between -180 and 180))
);

create table if not exists public.mission_objectives (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  title text not null,
  description text,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  team text not null default 'NEUTRAL' check (team in ('ALFA','BRAVO','NEUTRAL')),
  completed boolean not null default false,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.game_events (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  event_type text not null,
  description text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

-- 2) Funzione di verifica appartenenza. SECURITY DEFINER evita ricorsione RLS.
create or replace function public.is_game_member(p_game uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.game_members as gm
    where gm.game_id = p_game
      and gm.user_id = auth.uid()
  );
$$;

-- 3) Crea partita e registra automaticamente l'organizzatore.
-- I nomi delle variabili locali sono distinti dalle colonne restituite.
create or replace function public.create_game(
  p_name text,
  p_mode text,
  p_code text,
  p_player_name text
)
returns table(game_id uuid, game_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_code text;
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'Accesso non autenticato';
  end if;

  v_name := nullif(btrim(coalesce(p_name, '')), '');
  v_code := upper(btrim(coalesce(p_code, '')));

  if v_name is null then
    raise exception 'Nome partita obbligatorio';
  end if;
  if length(v_code) < 5 or length(v_code) > 10 then
    raise exception 'Codice partita non valido';
  end if;

  insert into public.games(name, mode, game_code, created_by)
  values (v_name, coalesce(nullif(btrim(p_mode), ''), 'MilSim'), v_code, auth.uid())
  returning id into v_id;

  insert into public.game_members(game_id, user_id, player_name, team)
  values (
    v_id,
    auth.uid(),
    left(coalesce(nullif(btrim(p_player_name), ''), 'Organizzatore'), 28),
    'ORGANIZZATORE'
  )
  on conflict (game_id, user_id) do update
    set player_name = excluded.player_name,
        team = excluded.team;

  return query select v_id, v_code;
end;
$$;

-- 4) Entra in partita. La colonna game_code è sempre qualificata con alias g:
-- questo risolve l'errore "column reference game_code is ambiguous".
create or replace function public.join_game(
  p_code text,
  p_name text,
  p_team text
)
returns table(game_id uuid, game_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game public.games%rowtype;
  v_player_name text;
  v_team text;
begin
  if auth.uid() is null then
    raise exception 'Accesso non autenticato';
  end if;

  v_player_name := nullif(btrim(coalesce(p_name, '')), '');
  if v_player_name is null then
    raise exception 'Nominativo obbligatorio';
  end if;

  select g.*
    into v_game
  from public.games as g
  where g.game_code = upper(btrim(coalesce(p_code, '')))
  limit 1;

  if not found then
    raise exception 'Codice partita non trovato';
  end if;

  v_team := case
    when p_team in ('ALFA', 'BRAVO') then p_team
    else 'ALFA'
  end;

  insert into public.game_members(game_id, user_id, player_name, team)
  values (v_game.id, auth.uid(), left(v_player_name, 28), v_team)
  on conflict (game_id, user_id) do update
    set player_name = excluded.player_name,
        team = excluded.team;

  return query select v_game.id, v_game.game_code;
end;
$$;

-- 5) Row Level Security
alter table public.games enable row level security;
alter table public.game_members enable row level security;
alter table public.mission_objectives enable row level security;
alter table public.game_events enable row level security;

drop policy if exists "members read games" on public.games;
create policy "members read games" on public.games
  for select to authenticated
  using (public.is_game_member(id));

drop policy if exists "members read members" on public.game_members;
create policy "members read members" on public.game_members
  for select to authenticated
  using (public.is_game_member(game_id));

drop policy if exists "self update own member" on public.game_members;
create policy "self update own member" on public.game_members
  for update to authenticated
  using (user_id = auth.uid() and public.is_game_member(game_id))
  with check (user_id = auth.uid() and public.is_game_member(game_id));

drop policy if exists "members read objectives" on public.mission_objectives;
create policy "members read objectives" on public.mission_objectives
  for select to authenticated
  using (public.is_game_member(game_id));

drop policy if exists "members add objectives" on public.mission_objectives;
create policy "members add objectives" on public.mission_objectives
  for insert to authenticated
  with check (public.is_game_member(game_id) and created_by = auth.uid());

drop policy if exists "members update objectives" on public.mission_objectives;
create policy "members update objectives" on public.mission_objectives
  for update to authenticated
  using (public.is_game_member(game_id))
  with check (public.is_game_member(game_id));

drop policy if exists "members delete objectives" on public.mission_objectives;
create policy "members delete objectives" on public.mission_objectives
  for delete to authenticated
  using (public.is_game_member(game_id));

drop policy if exists "members read events" on public.game_events;
create policy "members read events" on public.game_events
  for select to authenticated
  using (public.is_game_member(game_id));

drop policy if exists "members add events" on public.game_events;
create policy "members add events" on public.game_events
  for insert to authenticated
  with check (public.is_game_member(game_id) and created_by = auth.uid());

-- 6) Permessi minimi usati dall'app
 grant usage on schema public to authenticated;
 grant select on public.games, public.game_members, public.mission_objectives, public.game_events to authenticated;
 grant update(player_name, team, lat, lng, location_updated_at) on public.game_members to authenticated;
 grant insert, update, delete on public.mission_objectives to authenticated;
 grant insert on public.game_events to authenticated;
 grant execute on function public.is_game_member(uuid) to authenticated;
 grant execute on function public.create_game(text, text, text, text) to authenticated;
 grant execute on function public.join_game(text, text, text) to authenticated;

-- 7) Realtime: aggiunge le tabelle solo se non sono già pubblicate.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.game_members;
    exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.mission_objectives;
    exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.game_events;
    exception when duplicate_object then null; end;
  end if;
end;
$$;

-- 8) Verifica finale: deve restituire le tre funzioni previste.
select p.proname as funzione, pg_get_function_identity_arguments(p.oid) as argomenti
from pg_proc as p
join pg_namespace as n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('is_game_member', 'create_game', 'join_game')
order by p.proname;

-- NOTA: Anonymous Sign-ins deve restare attivo in Authentication > Sign In / Providers.
-- La Edge Function generate-mission resta separata e usa OPENAI_API_KEY nei Secrets.
