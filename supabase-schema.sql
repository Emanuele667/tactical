-- TACTICAL AI - schema iniziale Supabase
-- Eseguire una sola volta in Supabase > SQL Editor.
create extension if not exists pgcrypto;

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
  unique(game_id,user_id),
  check ((lat is null and lng is null) or (lat between -90 and 90 and lng between -180 and 180))
);
create table if not exists public.mission_objectives (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  title text not null,
  description text,
  lat double precision not null check(lat between -90 and 90),
  lng double precision not null check(lng between -180 and 180),
  team text not null default 'NEUTRAL' check(team in ('ALFA','BRAVO','NEUTRAL')),
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

create or replace function public.is_game_member(p_game uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.game_members gm where gm.game_id=p_game and gm.user_id=auth.uid()); $$;

drop function if exists public.create_game(text,text,text);
create or replace function public.create_game(p_name text,p_mode text,p_code text,p_player_name text)
returns table(game_id uuid,game_code text)
language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'Accesso non autenticato'; end if;
 if length(trim(coalesce(p_name,'')))=0 then raise exception 'Nome partita obbligatorio'; end if;
 if length(p_code)<5 or length(p_code)>10 then raise exception 'Codice partita non valido'; end if;
 insert into public.games(name,mode,game_code,created_by) values(trim(p_name),coalesce(p_mode,'MilSim'),upper(p_code),auth.uid()) returning id into v_id;
 insert into public.game_members(game_id,user_id,player_name,team) values(v_id,auth.uid(),left(coalesce(nullif(trim(p_player_name),''),'Organizzatore'),28),'ORGANIZZATORE');
 return query select v_id,upper(p_code);
end; $$;

create or replace function public.join_game(p_code text,p_name text,p_team text)
returns table(game_id uuid,game_code text)
language plpgsql security definer set search_path=public
as $$
declare v_game public.games%rowtype;
begin
 if auth.uid() is null then raise exception 'Accesso non autenticato'; end if;
 if length(trim(coalesce(p_name,'')))=0 then raise exception 'Nominativo obbligatorio'; end if;
 select * into v_game from public.games where game_code=upper(trim(p_code));
 if not found then raise exception 'Codice partita non trovato'; end if;
 insert into public.game_members(game_id,user_id,player_name,team)
 values(v_game.id,auth.uid(),left(trim(p_name),28),case when p_team in ('ALFA','BRAVO','ORGANIZZATORE') then p_team else 'ALFA' end)
 on conflict(game_id,user_id) do update set player_name=excluded.player_name,team=excluded.team;
 return query select v_game.id,v_game.game_code;
end; $$;

alter table public.games enable row level security;
alter table public.game_members enable row level security;
alter table public.mission_objectives enable row level security;
alter table public.game_events enable row level security;

drop policy if exists "members read games" on public.games;
create policy "members read games" on public.games for select to authenticated using (public.is_game_member(id));
drop policy if exists "members read members" on public.game_members;
create policy "members read members" on public.game_members for select to authenticated using (public.is_game_member(game_id));
drop policy if exists "self update own member" on public.game_members;
create policy "self update own member" on public.game_members for update to authenticated using (user_id=auth.uid() and public.is_game_member(game_id)) with check (user_id=auth.uid() and public.is_game_member(game_id));
drop policy if exists "members read objectives" on public.mission_objectives;
create policy "members read objectives" on public.mission_objectives for select to authenticated using (public.is_game_member(game_id));
drop policy if exists "members add objectives" on public.mission_objectives;
create policy "members add objectives" on public.mission_objectives for insert to authenticated with check (public.is_game_member(game_id) and created_by=auth.uid());
drop policy if exists "members update objectives" on public.mission_objectives;
create policy "members update objectives" on public.mission_objectives for update to authenticated using (public.is_game_member(game_id)) with check (public.is_game_member(game_id));
drop policy if exists "members delete objectives" on public.mission_objectives;
create policy "members delete objectives" on public.mission_objectives for delete to authenticated using (public.is_game_member(game_id));
drop policy if exists "members read events" on public.game_events;
create policy "members read events" on public.game_events for select to authenticated using (public.is_game_member(game_id));
drop policy if exists "members add events" on public.game_events;
create policy "members add events" on public.game_events for insert to authenticated with check (public.is_game_member(game_id) and created_by=auth.uid());

grant usage on schema public to anon, authenticated;
grant select on public.games,public.game_members,public.mission_objectives,public.game_events to authenticated;
grant update(lat,lng,location_updated_at,player_name,team) on public.game_members to authenticated;
grant insert,update,delete on public.mission_objectives to authenticated;
grant insert on public.game_events to authenticated;
grant execute on function public.create_game(text,text,text,text) to authenticated;
grant execute on function public.join_game(text,text,text) to authenticated;

-- Abilitare Realtime per tabelle sincronizzate (ignora se già presenti):
do $$ begin
 alter publication supabase_realtime add table public.game_members;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
 alter publication supabase_realtime add table public.mission_objectives;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
 alter publication supabase_realtime add table public.game_events;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- Attivare Auth > Providers > Anonymous Sign-ins in Supabase.
