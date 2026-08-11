-- =====================================================================
-- SCHEMA PATCH 10 — audience identity, continuous voting, leaderboard
-- Run once, AFTER schema-patch-9-lifelines-and-buzzer-flow.sql.
-- =====================================================================

-- 1. Audience identity. Phone is REQUIRED and is the uniqueness key —
-- without it there's no way to stop someone re-registering on a second
-- device to vote twice, which defeats the point of a prize leaderboard.
create table if not exists public.quiz_audience_participants (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.quiz_events(id) on delete cascade,
  name text not null,
  phone text not null,
  device_id text,
  created_at timestamptz default now(),
  unique(event_id, phone)
);
alter table public.quiz_audience_participants enable row level security;
drop policy if exists p_admin_read_participants on public.quiz_audience_participants;
create policy p_admin_read_participants on public.quiz_audience_participants for select using (public.is_admin());
-- no public select policy: a participant's own row comes back as the RPC's
-- return value at registration time, not via a table query, so their name/
-- phone is never broadcast to other anonymous clients.

-- 2. Register-or-rejoin: same phone on a new device just re-attaches
-- (updates device_id), same as team join_team's pattern.
create or replace function public.register_or_join_audience(p_event_id uuid, p_name text, p_phone text, p_device_id text)
returns public.quiz_audience_participants
language plpgsql security definer set search_path = public as $$
declare v_p public.quiz_audience_participants;
begin
  if coalesce(trim(p_name),'') = '' then raise exception 'Name is required'; end if;
  if coalesce(trim(p_phone),'') = '' then raise exception 'Mobile number is required'; end if;

  select * into v_p from public.quiz_audience_participants where event_id = p_event_id and phone = p_phone;
  if v_p.id is not null then
    update public.quiz_audience_participants set device_id = p_device_id where id = v_p.id returning * into v_p;
    return v_p;
  end if;

  insert into public.quiz_audience_participants (event_id, name, phone, device_id)
    values (p_event_id, p_name, p_phone, p_device_id)
    returning * into v_p;
  return v_p;
end; $$;

-- 3. Votes now key off a stable participant identity, not a per-device
-- random id, so it survives the participant switching devices and so we
-- can compute a real per-person leaderboard at the end.
alter table public.quiz_audience_votes alter column session_id drop not null;
alter table public.quiz_audience_votes add column if not exists participant_id uuid references public.quiz_audience_participants(id);
create unique index if not exists quiz_audience_votes_question_participant_key
  on public.quiz_audience_votes(question_id, participant_id) where participant_id is not null;

-- 4. submit_vote: voting is open continuously for whatever question is
-- currently live (not gated behind an explicit "start poll" click), PLUS
-- during a lifeline-triggered final-call extension. Locked the moment the
-- question moves to RESULT_REVEAL/QUESTION_COMPLETE or a new question
-- replaces it (caller passes p_question_id so a stale client can't vote
-- on a question that's no longer current).
create or replace function public.submit_vote(p_session_id uuid, p_participant_id uuid, p_question_id uuid, p_option text)
returns public.quiz_audience_votes
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session; v_row public.quiz_audience_votes;
begin
  select * into v_session from public.quiz_session where id = p_session_id;

  if v_session.current_question_id is distinct from p_question_id then
    raise exception 'This question is no longer live';
  end if;

  if v_session.state in ('RESULT_REVEAL','QUESTION_COMPLETE') then
    raise exception 'Voting has closed for this question';
  end if;

  insert into public.quiz_audience_votes (question_id, participant_id, option)
    values (p_question_id, p_participant_id, p_option)
    returning * into v_row;
  return v_row;
exception
  when unique_violation then raise exception 'You already answered this question';
end; $$;

-- 5. request_lifeline: the AUDIENCE lifeline no longer starts a fresh
-- poll — voting has been running continuously in the background since the
-- question appeared. It just pauses the main timer and gives stragglers
-- an explicit 15s final call; the tally at reveal includes every vote
-- collected the whole time the question was live, not just these 15s.
create or replace function public.request_lifeline(p_session_id uuid, p_team_id uuid, p_lifeline_type text)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare
  v_session public.quiz_session; v_round public.quiz_rounds; v_question public.quiz_questions;
  v_remaining int; v_eliminated text[];
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  select * into v_session from public.quiz_session where id = p_session_id;
  select * into v_round from public.quiz_rounds where id = v_session.current_round_id;
  select * into v_question from public.quiz_questions where id = v_session.current_question_id;

  if v_round.has_buzzer or v_round.has_rapid_fire then
    raise exception 'Lifelines only apply in simple (no buzzer / no rapid fire) rounds';
  end if;
  if v_session.current_question_id is null then
    raise exception 'No question is currently showing';
  end if;

  insert into public.quiz_question_lifeline_uses (question_id, team_id, lifeline_type)
    values (v_session.current_question_id, p_team_id, p_lifeline_type);

  update public.quiz_lifelines set status = 'USED', used_at = now()
    where team_id = p_team_id and lifeline_type = p_lifeline_type and status = 'AVAILABLE';
  if not found then raise exception 'This lifeline is not available for this team'; end if;

  if v_session.timer_end is not null and not v_session.timer_paused then
    v_remaining := greatest(extract(epoch from (v_session.timer_end - now()))::int, 0);
  else
    v_remaining := v_session.timer_remaining_seconds;
  end if;

  if p_lifeline_type = 'FIFTY_FIFTY' then
    select array(select unnest(array['A','B','C','D']) except select v_question.correct_option order by random() limit 2)
      into v_eliminated;
  else
    v_eliminated := '{}';
  end if;

  update public.quiz_session
    set timer_paused = true, timer_remaining_seconds = v_remaining,
        lifeline_kind = p_lifeline_type, lifeline_team_id = p_team_id, lifeline_active = true,
        eliminated_options = v_eliminated,
        lifeline_timer_end = case
          when p_lifeline_type = 'AUDIENCE' then now() + interval '15 seconds'
          when p_lifeline_type in ('EXPERT','TEAM_ADVICE') then now() + interval '30 seconds'
          else null end,
        lifeline_poll_results = null,
        updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
exception
  when unique_violation then raise exception 'This team already used a lifeline on this question';
end; $$;

-- 6. End-of-quiz leaderboard: correct answers out of total answered, for
-- the admin to eyeball and pick top N winners from. Only counts questions
-- that had a correct_option set (all of them, in practice).
create or replace function public.get_audience_leaderboard(p_event_id uuid)
returns table(participant_id uuid, name text, phone text, correct_count bigint, total_answered bigint)
language sql
stable
as $$
  select
    p.id, p.name, p.phone,
    count(*) filter (where v.option = q.correct_option) as correct_count,
    count(*) as total_answered
  from public.quiz_audience_participants p
  join public.quiz_audience_votes v on v.participant_id = p.id
  join public.quiz_questions q on q.id = v.question_id
  where p.event_id = p_event_id and public.is_admin()
  group by p.id, p.name, p.phone
  order by correct_count desc, total_answered desc, p.created_at asc;
$$;
