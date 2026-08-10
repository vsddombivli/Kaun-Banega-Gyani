-- =====================================================================
-- VSD QUIZ SYSTEM — SUPABASE SCHEMA
-- Run this whole file once in Supabase SQL editor (Project > SQL Editor).
-- Safe to re-run: uses IF NOT EXISTS / DROP ... IF EXISTS guards.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. EXTENSIONS
-- ---------------------------------------------------------------------
create extension if not exists "pgcrypto"; -- gen_random_uuid()

-- ---------------------------------------------------------------------
-- 1. ADMIN TABLE (who is allowed to do admin things)
-- Populate manually after creating an Auth user:
--   insert into public.admins (user_id, name) values ('<auth-uid>', 'Volunteer Name');
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text,
  created_at timestamptz default now()
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 2. CORE TABLES
-- ---------------------------------------------------------------------
create table if not exists public.quiz_events (
  id uuid primary key default gen_random_uuid(),
  event_name text not null,
  event_date date,
  status text not null default 'DRAFT' check (status in ('DRAFT','LIVE','ENDED')),
  current_round_id uuid,
  current_question_id uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists public.quiz_rounds (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.quiz_events(id) on delete cascade,
  round_no int not null,
  round_name text not null,
  round_type text not null default 'MCQ' check (round_type in ('MCQ','BUZZER','RAPID_FIRE','AUDIENCE','VISUAL','LIFELINE')),
  description text,
  -- per-round scoring / rules overrides (falls back to event defaults if null)
  first_correct_points int default 100,
  first_wrong_points int default -100,
  second_correct_points int default 50,
  second_wrong_points int default -100,
  buzzer_window_seconds int default 30,
  rapid_fire_points int default 100,
  status text not null default 'PENDING' check (status in ('PENDING','ACTIVE','DONE')),
  created_at timestamptz default now()
);

create table if not exists public.quiz_team_names (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.quiz_events(id) on delete cascade,
  team_name text not null,
  taken boolean not null default false,
  unique(event_id, team_name)
);

create table if not exists public.quiz_teams (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.quiz_events(id) on delete cascade,
  team_name text not null,
  team_code text not null unique, -- shown on QR, used to join /team
  team_number int,
  points int not null default 0,
  member_count int default 0,
  captain_name text,
  phone text,
  pathshala text,
  device_id text, -- currently bound device/session, for anti-hijack
  active boolean not null default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists public.quiz_team_members (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.quiz_teams(id) on delete cascade,
  member_name text not null
);

create table if not exists public.quiz_questions (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.quiz_rounds(id) on delete cascade,
  question_no int not null,
  question text not null,
  option_a text,
  option_b text,
  option_c text,
  option_d text,
  correct_option text check (correct_option in ('A','B','C','D')),
  points int default 100,
  time_limit int default 30,
  question_type text not null default 'MCQ' check (question_type in ('MCQ','BUZZER','AUDIENCE','RAPID_FIRE','VISUAL')),
  difficulty text default 'MEDIUM',
  image_url text,
  explanation text,
  created_at timestamptz default now()
);

-- Public-safe view: never exposes correct_option to non-admins
create or replace view public.quiz_questions_public as
  select id, round_id, question_no, question, option_a, option_b, option_c, option_d,
         points, time_limit, question_type, difficulty, image_url
  from public.quiz_questions;

-- Central live-state table (one row per event)
create table if not exists public.quiz_session (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null unique references public.quiz_events(id) on delete cascade,
  current_round_id uuid references public.quiz_rounds(id),
  current_question_id uuid references public.quiz_questions(id),
  state text not null default 'WAITING' check (state in (
    'WAITING','QUESTION_DISPLAY','BUZZER_OPEN','BUZZER_CLOSED','ANSWERING',
    'ANSWER_REVIEW','PASSING','AUDIENCE_POLL_OPEN','AUDIENCE_POLL_CLOSED',
    'RESULT_REVEAL','QUESTION_COMPLETE','RAPID_FIRE_ACTIVE','LEADERBOARD')),
  answering_team_id uuid references public.quiz_teams(id),
  answering_position int, -- 1 = first buzzer, 2 = second buzzer
  buzzer_open boolean not null default false,
  audience_poll_open boolean not null default false,
  timer_end timestamptz,
  last_result jsonb, -- {team_id, correct, points} for presentation to render
  updated_at timestamptz default now()
);

create table if not exists public.quiz_buzzers (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.quiz_questions(id) on delete cascade,
  team_id uuid not null references public.quiz_teams(id) on delete cascade,
  device_id text,
  server_timestamp timestamptz not null default now(),
  sequence_no int not null,
  eligible boolean not null default false, -- true only for first 2 per question
  created_at timestamptz default now(),
  unique(question_id, team_id) -- one buzz per team per question
);

create table if not exists public.quiz_audience_votes (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.quiz_questions(id) on delete cascade,
  session_id text not null, -- random id stored in audience device's localStorage
  option text not null check (option in ('A','B','C','D')),
  created_at timestamptz default now(),
  unique(question_id, session_id) -- one vote per device per question
);

create table if not exists public.quiz_scores (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.quiz_teams(id) on delete cascade,
  question_id uuid references public.quiz_questions(id),
  points_change int not null,
  reason text,
  admin_id uuid,
  created_at timestamptz default now()
);

create table if not exists public.quiz_lifelines (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.quiz_teams(id) on delete cascade,
  lifeline_type text not null check (lifeline_type in ('FIFTY_FIFTY','AUDIENCE','EXPERT','TEAM_ADVICE')),
  status text not null default 'LOCKED' check (status in ('LOCKED','AVAILABLE','USED')),
  unlocked_at timestamptz,
  used_at timestamptz,
  revived_at timestamptz,
  unique(team_id, lifeline_type)
);

create table if not exists public.quiz_lifeline_milestones (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.quiz_events(id) on delete cascade,
  points_threshold int not null,
  unlocks text not null check (unlocks in ('FIFTY_FIFTY','AUDIENCE','EXPERT','TEAM_ADVICE','REVIVE')),
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY
-- Rule of thumb: public (anon) may SELECT read-mostly state, but every
-- write that matters (buzzer, vote, score, state transition) goes
-- through a SECURITY DEFINER function below, never a raw insert/update.
-- ---------------------------------------------------------------------
alter table public.quiz_events enable row level security;
alter table public.quiz_rounds enable row level security;
alter table public.quiz_team_names enable row level security;
alter table public.quiz_teams enable row level security;
alter table public.quiz_team_members enable row level security;
alter table public.quiz_questions enable row level security;
alter table public.quiz_session enable row level security;
alter table public.quiz_buzzers enable row level security;
alter table public.quiz_audience_votes enable row level security;
alter table public.quiz_scores enable row level security;
alter table public.quiz_lifelines enable row level security;
alter table public.quiz_lifeline_milestones enable row level security;
alter table public.admins enable row level security;

-- Public read policies (safe columns only; quiz_questions itself is NOT
-- publicly readable — use quiz_questions_public view instead)
drop policy if exists p_read_events on public.quiz_events;
create policy p_read_events on public.quiz_events for select using (true);

drop policy if exists p_read_rounds on public.quiz_rounds;
create policy p_read_rounds on public.quiz_rounds for select using (true);

drop policy if exists p_read_team_names on public.quiz_team_names;
create policy p_read_team_names on public.quiz_team_names for select using (true);

drop policy if exists p_read_teams on public.quiz_teams;
create policy p_read_teams on public.quiz_teams for select using (true);

drop policy if exists p_read_session on public.quiz_session;
create policy p_read_session on public.quiz_session for select using (true);

drop policy if exists p_read_lifelines on public.quiz_lifelines;
create policy p_read_lifelines on public.quiz_lifelines for select using (true);

-- quiz_questions: admins only (raw table, has correct_option)
drop policy if exists p_admin_all_questions on public.quiz_questions;
create policy p_admin_all_questions on public.quiz_questions for all
  using (public.is_admin()) with check (public.is_admin());

-- Admin full-access policies on everything else
drop policy if exists p_admin_all_events on public.quiz_events;
create policy p_admin_all_events on public.quiz_events for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_admin_all_rounds on public.quiz_rounds;
create policy p_admin_all_rounds on public.quiz_rounds for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_admin_all_team_names on public.quiz_team_names;
create policy p_admin_all_team_names on public.quiz_team_names for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_admin_all_teams on public.quiz_teams;
create policy p_admin_all_teams on public.quiz_teams for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_admin_all_members on public.quiz_team_members;
create policy p_admin_all_members on public.quiz_team_members for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists p_read_members on public.quiz_team_members;
create policy p_read_members on public.quiz_team_members for select using (true);

drop policy if exists p_admin_all_session on public.quiz_session;
create policy p_admin_all_session on public.quiz_session for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_admin_read_buzzers on public.quiz_buzzers;
create policy p_admin_read_buzzers on public.quiz_buzzers for select using (public.is_admin());
-- Teams should see buzzer order too, but never insert directly (RPC only)
drop policy if exists p_public_read_buzzers on public.quiz_buzzers;
create policy p_public_read_buzzers on public.quiz_buzzers for select using (true);

drop policy if exists p_admin_read_votes on public.quiz_audience_votes;
create policy p_admin_read_votes on public.quiz_audience_votes for select using (public.is_admin());

drop policy if exists p_admin_all_scores on public.quiz_scores;
create policy p_admin_all_scores on public.quiz_scores for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_admin_all_lifelines on public.quiz_lifelines;
create policy p_admin_all_lifelines on public.quiz_lifelines for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists p_admin_all_milestones on public.quiz_lifeline_milestones;
create policy p_admin_all_milestones on public.quiz_lifeline_milestones for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists p_read_milestones on public.quiz_lifeline_milestones;
create policy p_read_milestones on public.quiz_lifeline_milestones for select using (true);

drop policy if exists p_admin_read_admins on public.admins;
create policy p_admin_read_admins on public.admins for select using (public.is_admin());

-- ---------------------------------------------------------------------
-- 4. SERVER-AUTHORITATIVE RPC FUNCTIONS
-- These are the ONLY way non-admin clients change state. Each function
-- re-checks the live session state/timer server-side, so a client with
-- a stale screen or a modified local clock cannot cheat.
-- ---------------------------------------------------------------------

-- 4a. Team registration (atomic "claim a team name")
create or replace function public.register_team(
  p_event_id uuid,
  p_team_name text,
  p_captain_name text,
  p_phone text,
  p_pathshala text,
  p_members text[]
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team_id uuid;
  v_code text;
  m text;
begin
  if array_length(p_members,1) is null or array_length(p_members,1) < 5 or array_length(p_members,1) > 7 then
    raise exception 'Team must have between 5 and 7 members';
  end if;

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

  insert into public.quiz_teams (event_id, team_name, team_code, captain_name, phone, pathshala, member_count)
  values (p_event_id, p_team_name, v_code, p_captain_name, p_phone, p_pathshala, array_length(p_members,1))
  returning id into v_team_id;

  foreach m in array p_members loop
    insert into public.quiz_team_members(team_id, member_name) values (v_team_id, m);
  end loop;

  return v_team_id; -- caller should also fetch team_code
end;
$$;

-- 4b. Team joins with a code -> binds a device_id (basic anti-hijack)
create or replace function public.join_team(p_team_code text, p_device_id text)
returns public.quiz_teams
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team public.quiz_teams;
begin
  select * into v_team from public.quiz_teams where team_code = upper(p_team_code) and active = true;
  if v_team.id is null then
    raise exception 'Invalid team code';
  end if;

  if v_team.device_id is not null and v_team.device_id <> p_device_id then
    -- Allow admin to clear device_id manually to free up a team; otherwise block hijack
    raise exception 'This team is already active on another device. Ask admin to release it.';
  end if;

  update public.quiz_teams set device_id = p_device_id, updated_at = now() where id = v_team.id
    returning * into v_team;

  return v_team;
end;
$$;

-- 4c. Admin releases a team's bound device (e.g. team lost/swapped phone)
create or replace function public.admin_release_team_device(p_team_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin only';
  end if;
  update public.quiz_teams set device_id = null where id = p_team_id;
end;
$$;

-- 4d. Admin pushes a question live
create or replace function public.push_question(p_session_id uuid, p_question_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
  v_round_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Admin only';
  end if;

  select round_id into v_round_id from public.quiz_questions where id = p_question_id;

  update public.quiz_session
    set current_question_id = p_question_id,
        current_round_id = v_round_id,
        state = 'QUESTION_DISPLAY',
        buzzer_open = false,
        audience_poll_open = false,
        answering_team_id = null,
        answering_position = null,
        timer_end = null,
        last_result = null,
        updated_at = now()
    where id = p_session_id
    returning * into v_session;

  return v_session;
end;
$$;

-- 4e. Admin opens the 30s buzzer window
create or replace function public.open_buzzer(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
  v_seconds int;
begin
  if not public.is_admin() then
    raise exception 'Admin only';
  end if;

  select coalesce(r.buzzer_window_seconds, 30) into v_seconds
    from public.quiz_session s
    join public.quiz_rounds r on r.id = s.current_round_id
    where s.id = p_session_id;

  update public.quiz_session
    set state = 'BUZZER_OPEN',
        buzzer_open = true,
        timer_end = now() + make_interval(secs => coalesce(v_seconds,30)),
        updated_at = now()
    where id = p_session_id
    returning * into v_session;

  return v_session;
end;
$$;

-- 4f. Team submits a buzzer press — the security-critical function.
-- Rejects: buzzer not open, window expired (server clock), duplicate team.
-- Assigns sequence_no atomically and marks the first 2 eligible.
create or replace function public.submit_buzzer(p_session_id uuid, p_team_id uuid, p_device_id text)
returns public.quiz_buzzers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
  v_row public.quiz_buzzers;
  v_count int;
begin
  select * into v_session from public.quiz_session where id = p_session_id for update;

  if v_session.state <> 'BUZZER_OPEN' or v_session.buzzer_open is not true then
    raise exception 'Buzzer is not open';
  end if;

  if now() >= v_session.timer_end then
    raise exception 'Buzzer window has closed';
  end if;

  -- device must match the team's bound device (prevents another device buzzing as this team)
  if not exists (select 1 from public.quiz_teams where id = p_team_id and (device_id = p_device_id or device_id is null)) then
    raise exception 'Device not authorized for this team';
  end if;

  select count(*) into v_count from public.quiz_buzzers where question_id = v_session.current_question_id;

  insert into public.quiz_buzzers (question_id, team_id, device_id, server_timestamp, sequence_no, eligible)
  values (v_session.current_question_id, p_team_id, p_device_id, now(), v_count + 1, v_count < 2)
  returning * into v_row; -- unique(question_id, team_id) blocks duplicate buzzes

  return v_row;
exception
  when unique_violation then
    raise exception 'Team already buzzed for this question';
end;
$$;

-- 4g. Anyone (client heartbeat) can request the buzzer be closed, but it
-- only actually closes once the server-side timer has really elapsed —
-- so a client cannot force an early close.
create or replace function public.try_close_buzzer(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
begin
  select * into v_session from public.quiz_session where id = p_session_id;

  if v_session.state = 'BUZZER_OPEN' and now() >= v_session.timer_end then
    update public.quiz_session
      set state = 'BUZZER_CLOSED', buzzer_open = false, updated_at = now()
      where id = p_session_id
      returning * into v_session;
  end if;

  return v_session;
end;
$$;

-- 4h. Admin advances to first/second eligible team's answering turn
create or replace function public.advance_to_next_answerer(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
  v_next record;
  v_position int;
begin
  if not public.is_admin() then
    raise exception 'Admin only';
  end if;

  select * into v_session from public.quiz_session where id = p_session_id;
  v_position := coalesce(v_session.answering_position, 0) + 1;

  if v_position > 2 then
    raise exception 'No third pass allowed';
  end if;

  select * into v_next from public.quiz_buzzers
    where question_id = v_session.current_question_id and eligible = true
    order by sequence_no asc
    offset (v_position - 1) limit 1;

  if v_next.team_id is null then
    -- no more eligible teams (e.g. only one team buzzed)
    update public.quiz_session set state = 'QUESTION_COMPLETE', answering_team_id = null, answering_position = null, updated_at = now()
      where id = p_session_id returning * into v_session;
    return v_session;
  end if;

  update public.quiz_session
    set state = 'ANSWERING', answering_team_id = v_next.team_id, answering_position = v_position, updated_at = now()
    where id = p_session_id
    returning * into v_session;

  return v_session;
end;
$$;

-- 4i. Admin marks the currently-answering team correct/wrong, applies
-- points per round config, logs to quiz_scores, and moves state on.
create or replace function public.mark_buzzer_answer(p_session_id uuid, p_correct boolean)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
  v_round public.quiz_rounds;
  v_points int;
begin
  if not public.is_admin() then
    raise exception 'Admin only';
  end if;

  select * into v_session from public.quiz_session where id = p_session_id;
  select * into v_round from public.quiz_rounds where id = v_session.current_round_id;

  if v_session.answering_team_id is null then
    raise exception 'No team is currently answering';
  end if;

  if v_session.answering_position = 1 then
    v_points := case when p_correct then v_round.first_correct_points else v_round.first_wrong_points end;
  else
    v_points := case when p_correct then v_round.second_correct_points else v_round.second_wrong_points end;
  end if;

  update public.quiz_teams set points = points + v_points, updated_at = now() where id = v_session.answering_team_id;

  insert into public.quiz_scores (team_id, question_id, points_change, reason, admin_id)
  values (v_session.answering_team_id, v_session.current_question_id,
          v_points, case when p_correct then 'Buzzer correct' else 'Buzzer wrong' end, auth.uid());

  update public.quiz_session
    set last_result = jsonb_build_object('team_id', v_session.answering_team_id, 'correct', p_correct, 'points', v_points),
        state = case
          when p_correct then 'QUESTION_COMPLETE'
          when v_session.answering_position = 1 then 'PASSING'
          else 'QUESTION_COMPLETE'
        end,
        updated_at = now()
    where id = p_session_id
    returning * into v_session;

  perform public.check_lifeline_milestones(v_session.answering_team_id);

  return v_session;
end;
$$;

-- 4j. Admin opens the audience poll
create or replace function public.open_audience_poll(p_session_id uuid, p_seconds int default 30)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
begin
  if not public.is_admin() then
    raise exception 'Admin only';
  end if;

  update public.quiz_session
    set state = 'AUDIENCE_POLL_OPEN', audience_poll_open = true,
        timer_end = now() + make_interval(secs => p_seconds), updated_at = now()
    where id = p_session_id
    returning * into v_session;

  return v_session;
end;
$$;

-- 4k. Audience submits a vote — one per device per question, window-checked server-side
create or replace function public.submit_vote(p_session_id uuid, p_session_device_id text, p_option text)
returns public.quiz_audience_votes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
  v_row public.quiz_audience_votes;
begin
  select * into v_session from public.quiz_session where id = p_session_id;

  if v_session.state <> 'AUDIENCE_POLL_OPEN' or v_session.audience_poll_open is not true then
    raise exception 'Audience poll is not open';
  end if;

  if now() >= v_session.timer_end then
    raise exception 'Voting window has closed';
  end if;

  insert into public.quiz_audience_votes (question_id, session_id, option)
  values (v_session.current_question_id, p_session_device_id, p_option)
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'You already voted on this question';
end;
$$;

create or replace function public.try_close_audience_poll(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
begin
  select * into v_session from public.quiz_session where id = p_session_id;

  if v_session.state = 'AUDIENCE_POLL_OPEN' and now() >= v_session.timer_end then
    update public.quiz_session
      set state = 'AUDIENCE_POLL_CLOSED', audience_poll_open = false, updated_at = now()
      where id = p_session_id
      returning * into v_session;
  end if;

  return v_session;
end;
$$;

-- Aggregate results (safe to expose: counts only, never individual votes)
create or replace function public.get_audience_results(p_question_id uuid)
returns table(option text, votes int, pct numeric)
language sql
stable
as $$
  with counts as (
    select o.option, count(v.id) as votes
    from (values ('A'),('B'),('C'),('D')) as o(option)
    left join public.quiz_audience_votes v
      on v.question_id = p_question_id and v.option = o.option
    group by o.option
  ), total as (
    select greatest(sum(votes),1) as t from counts
  )
  select c.option, c.votes, round(100.0 * c.votes / total.t, 1) as pct
  from counts c, total
  order by c.option;
$$;

-- 4l. Admin reveals result on presentation
create or replace function public.reveal_result(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  update public.quiz_session set state = 'RESULT_REVEAL', updated_at = now()
    where id = p_session_id returning * into v_session;
  return v_session;
end;
$$;

-- 4m. Admin ends the question / moves on
create or replace function public.complete_question(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  update public.quiz_session
    set state = 'QUESTION_COMPLETE', buzzer_open = false, audience_poll_open = false, updated_at = now()
    where id = p_session_id returning * into v_session;
  return v_session;
end;
$$;

-- 4n. Admin resets current question fully (recovery)
create or replace function public.reset_question(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;

  delete from public.quiz_buzzers where question_id = (select current_question_id from public.quiz_session where id = p_session_id);
  delete from public.quiz_audience_votes where question_id = (select current_question_id from public.quiz_session where id = p_session_id);

  update public.quiz_session
    set state = 'WAITING', buzzer_open = false, audience_poll_open = false,
        answering_team_id = null, answering_position = null, timer_end = null, last_result = null,
        updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
end;
$$;

-- 4o. Admin manual score adjustment (with audit log)
create or replace function public.adjust_score(p_team_id uuid, p_delta int, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  update public.quiz_teams set points = points + p_delta, updated_at = now() where id = p_team_id;
  insert into public.quiz_scores (team_id, points_change, reason, admin_id) values (p_team_id, p_delta, p_reason, auth.uid());
  perform public.check_lifeline_milestones(p_team_id);
end;
$$;

-- 4p. Rapid fire: award fixed points, no negative, no buzzer race
create or replace function public.mark_rapid_fire(p_team_id uuid, p_question_id uuid, p_correct boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_points int;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  select coalesce(rapid_fire_points,100) into v_points
    from public.quiz_rounds r join public.quiz_questions q on q.round_id = r.id
    where q.id = p_question_id;

  if p_correct then
    update public.quiz_teams set points = points + v_points, updated_at = now() where id = p_team_id;
    insert into public.quiz_scores(team_id, question_id, points_change, reason, admin_id)
      values (p_team_id, p_question_id, v_points, 'Rapid fire correct', auth.uid());
    perform public.check_lifeline_milestones(p_team_id);
  end if;
  -- wrong = no points change, per spec (no negative in rapid fire)
end;
$$;

-- 4q. Lifeline milestone check/unlock — called after any score change
create or replace function public.check_lifeline_milestones(p_team_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_points int;
  v_event_id uuid;
  m record;
begin
  select points, event_id into v_points, v_event_id from public.quiz_teams where id = p_team_id;

  for m in
    select * from public.quiz_lifeline_milestones
    where event_id = v_event_id and points_threshold <= v_points and unlocks <> 'REVIVE'
  loop
    insert into public.quiz_lifelines (team_id, lifeline_type, status, unlocked_at)
    values (p_team_id, m.unlocks, 'AVAILABLE', now())
    on conflict (team_id, lifeline_type) do update
      set status = 'AVAILABLE', unlocked_at = coalesce(public.quiz_lifelines.unlocked_at, now())
      where public.quiz_lifelines.status = 'LOCKED';
  end loop;
end;
$$;

-- 4r. Admin uses a lifeline for a team
create or replace function public.use_lifeline(p_team_id uuid, p_type text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  update public.quiz_lifelines set status = 'USED', used_at = now()
    where team_id = p_team_id and lifeline_type = p_type and status = 'AVAILABLE';
  if not found then
    raise exception 'Lifeline not available';
  end if;
end;
$$;

-- 4s. Admin revives a used lifeline (e.g. after 1000-pt milestone)
create or replace function public.revive_lifeline(p_team_id uuid, p_type text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  update public.quiz_lifelines set status = 'AVAILABLE', revived_at = now()
    where team_id = p_team_id and lifeline_type = p_type and status = 'USED';
end;
$$;

-- ---------------------------------------------------------------------
-- 5. REALTIME
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table public.quiz_session;
alter publication supabase_realtime add table public.quiz_teams;
alter publication supabase_realtime add table public.quiz_buzzers;
alter publication supabase_realtime add table public.quiz_lifelines;
alter publication supabase_realtime add table public.quiz_team_names;

-- ---------------------------------------------------------------------
-- 6. SEED HELPERS (optional convenience — edit and run manually)
-- ---------------------------------------------------------------------
-- insert into public.quiz_events (event_name, event_date, status) values ('VSD Prabhu Pooja & Guru Vandan Quiz', current_date, 'DRAFT');
-- insert into public.quiz_session (event_id) select id from public.quiz_events limit 1;
-- insert into public.quiz_team_names (event_id, team_name) select id, unnest(array['NAVKAR','ARIHANT','MAHAVIR','SIDDHARTH']) from public.quiz_events limit 1;
-- insert into public.quiz_lifeline_milestones (event_id, points_threshold, unlocks)
--   select id, v.t, v.u from public.quiz_events, (values (100,'FIFTY_FIFTY'),(300,'AUDIENCE'),(500,'EXPERT'),(750,'TEAM_ADVICE'),(1000,'REVIVE')) as v(t,u) limit 5;
