-- =====================================================================
-- SCHEMA PATCH 3 — team size = 5–7 INCLUDING captain, delete-to-resubmit
-- Run once in Supabase SQL Editor, AFTER schema-patch-2-registration.sql.
-- =====================================================================

-- 1. Replace register_team: total team size (captain + members) must be 5–7,
-- so the members array itself must be 4–6 entries. member_count now stores
-- the TOTAL including captain (was members-only before).
create or replace function public.register_team(
  p_event_id uuid,
  p_team_name text,
  p_captain_name text,
  p_captain_age int,
  p_phone text,
  p_pathshala text,
  p_members jsonb -- array of {"name": "...", "age": 12}, 4-6 entries
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
  if v_count is null or v_count < 4 or v_count > 6 then
    raise exception 'Team must have 5 to 7 members in total, including the captain';
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
  values (p_event_id, p_team_name, v_code, p_captain_name, p_captain_age, p_phone, p_pathshala, v_count + 1)
  returning id into v_team_id;

  for m in select * from jsonb_array_elements(p_members) loop
    insert into public.quiz_team_members (team_id, member_name, member_age)
    values (v_team_id, m->>'name', (m->>'age')::int);
  end loop;

  return v_team_id;
end;
$$;

-- 2. Admin: delete a registration entirely and free the team name slot
-- so the same or a different family can re-submit under that name.
create or replace function public.admin_delete_registration(p_team_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_team_name text;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;

  select event_id, team_name into v_event_id, v_team_name from public.quiz_teams where id = p_team_id;
  if v_event_id is null then raise exception 'Team not found'; end if;

  delete from public.quiz_scores where team_id = p_team_id;
  delete from public.quiz_buzzers where team_id = p_team_id;
  delete from public.quiz_lifelines where team_id = p_team_id;
  delete from public.quiz_team_members where team_id = p_team_id;
  delete from public.quiz_teams where id = p_team_id;

  update public.quiz_team_names set taken = false where event_id = v_event_id and team_name = v_team_name;
end;
$$;
