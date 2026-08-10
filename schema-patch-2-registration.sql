-- =====================================================================
-- SCHEMA PATCH 2 — Registration customization, ages, windows, auto-close
-- Run once in Supabase SQL Editor, AFTER supabase-schema.sql.
-- Safe to re-run.
-- =====================================================================

-- 1. Event-level registration settings
alter table public.quiz_events add column if not exists reg_header text default 'Team Registration';
alter table public.quiz_events add column if not exists reg_description text default 'One entry per mobile number. Once submitted, details can''t be self-edited — call the enquiry number for changes.';
alter table public.quiz_events add column if not exists reg_start timestamptz;
alter table public.quiz_events add column if not exists reg_end timestamptz;
alter table public.quiz_events add column if not exists reg_closed_manually boolean not null default false;

-- 2. Ages: captain + each member
alter table public.quiz_teams add column if not exists captain_age int;
alter table public.quiz_team_members add column if not exists member_age int;

-- Rename captain_name's meaning stays same column, just drop "parent" framing in UI only (no DB change needed).

-- 3. Registration status function — single source of truth for "is registration open"
-- open = within [reg_start, reg_end] window (if set) AND not manually closed AND at least one team name unclaimed
create or replace function public.get_registration_status(p_event_id uuid)
returns table(is_open boolean, reason text, slots_remaining int)
language plpgsql
stable
as $$
declare
  v_event public.quiz_events;
  v_remaining int;
begin
  select * into v_event from public.quiz_events where id = p_event_id;
  select count(*) into v_remaining from public.quiz_team_names where event_id = p_event_id and taken = false;

  if v_event.reg_closed_manually then
    return query select false, 'Registration has been closed by the organizers.', v_remaining;
  elsif v_event.reg_start is not null and now() < v_event.reg_start then
    return query select false, 'Registration has not opened yet.', v_remaining;
  elsif v_event.reg_end is not null and now() > v_event.reg_end then
    return query select false, 'Registration has closed.', v_remaining;
  elsif v_remaining <= 0 then
    return query select false, 'All team slots are filled — registration is full.', v_remaining;
  else
    return query select true, 'open', v_remaining;
  end if;
end;
$$;

-- 4. Replace register_team: 6 max members, ages mandatory when name present,
-- captain age required, and now re-checks registration status server-side
-- (client-side checks are UI convenience only — this is the real gate).
drop function if exists public.register_team(uuid, text, text, text, text, text[]);

create or replace function public.register_team(
  p_event_id uuid,
  p_team_name text,
  p_captain_name text,
  p_captain_age int,
  p_phone text,
  p_pathshala text,
  p_members jsonb -- array of {"name": "...", "age": 12}
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team_id uuid;
  v_code text;
  v_status record;
  m jsonb;
  v_count int;
begin
  select * into v_status from public.get_registration_status(p_event_id);
  if not v_status.is_open then
    raise exception '%', v_status.reason;
  end if;

  if p_captain_age is null then
    raise exception 'Captain age is required';
  end if;

  v_count := jsonb_array_length(p_members);
  if v_count is null or v_count < 5 or v_count > 6 then
    raise exception 'Team must have between 5 and 6 members';
  end if;

  for m in select * from jsonb_array_elements(p_members) loop
    if coalesce(trim(m->>'name'), '') <> '' and (m->>'age') is null then
      raise exception 'Age is required for member: %', (m->>'name');
    end if;
  end loop;

  if exists (select 1 from public.quiz_teams where event_id = p_event_id and phone = p_phone) then
    raise exception 'This phone number has already submitted a registration';
  end if;

  update public.quiz_team_names
    set taken = true
    where event_id = p_event_id and team_name = p_team_name and taken = false
    returning id into v_team_id;

  if v_team_id is null then
    raise exception 'Team name % is no longer available', p_team_name;
  end if;

  v_code := upper(substr(md5(random()::text), 1, 6));

  insert into public.quiz_teams (event_id, team_name, team_code, captain_name, captain_age, phone, pathshala, member_count)
  values (p_event_id, p_team_name, v_code, p_captain_name, p_captain_age, p_phone, p_pathshala, v_count)
  returning id into v_team_id;

  for m in select * from jsonb_array_elements(p_members) loop
    insert into public.quiz_team_members (team_id, member_name, member_age)
    values (v_team_id, m->>'name', (m->>'age')::int);
  end loop;

  return v_team_id;
end;
$$;

-- 5. Admin-only: update registration settings (header/description/window/manual close)
create or replace function public.update_registration_settings(
  p_event_id uuid,
  p_header text,
  p_description text,
  p_start timestamptz,
  p_end timestamptz,
  p_closed_manually boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  update public.quiz_events
    set reg_header = p_header, reg_description = p_description,
        reg_start = p_start, reg_end = p_end, reg_closed_manually = p_closed_manually,
        updated_at = now()
    where id = p_event_id;
end;
$$;

-- 6. Admin view: full registration detail (pathshala + every member's name/age)
-- Exposed as a table function so RLS on the underlying tables still applies via is_admin() checks inside.
create or replace function public.get_registrations(p_event_id uuid)
returns table(
  team_id uuid, team_name text, team_code text, pathshala text,
  captain_name text, captain_age int, phone text, member_count int,
  points int, created_at timestamptz, members jsonb
)
language sql
stable
as $$
  select t.id, t.team_name, t.team_code, t.pathshala, t.captain_name, t.captain_age,
         t.phone, t.member_count, t.points, t.created_at,
         coalesce(jsonb_agg(jsonb_build_object('name', tm.member_name, 'age', tm.member_age)) filter (where tm.id is not null), '[]'::jsonb) as members
  from public.quiz_teams t
  left join public.quiz_team_members tm on tm.team_id = t.id
  where t.event_id = p_event_id and public.is_admin()
  group by t.id
  order by t.created_at desc;
$$;
