-- =====================================================================
-- SCHEMA PATCH 11 — explicit round start/end, persistent round header
-- Run once, AFTER schema-patch-10-audience-identity-leaderboard.sql.
-- =====================================================================

-- 1. Session carries a denormalized copy of the active round's info so
-- every client can render the persistent header without an extra join —
-- cleared the moment the round ends.
alter table public.quiz_session add column if not exists active_round_name text;
alter table public.quiz_session add column if not exists active_round_no int;
alter table public.quiz_session add column if not exists active_round_description text;

-- 2. Admin starts a round: only one round can be active at a time (the
-- admin UI disables the button too, but this is the real guard).
create or replace function public.start_round(p_session_id uuid, p_round_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session; v_round public.quiz_rounds;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  select * into v_session from public.quiz_session where id = p_session_id;
  if v_session.active_round_name is not null then
    raise exception 'A round is already active — end it before starting another';
  end if;

  select * into v_round from public.quiz_rounds where id = p_round_id;
  update public.quiz_rounds set status = 'ACTIVE' where id = p_round_id;

  update public.quiz_session
    set current_round_id = p_round_id, current_question_id = null, state = 'WAITING',
        active_round_name = v_round.round_name, active_round_no = v_round.round_no,
        active_round_description = v_round.description,
        timer_end = null, timer_paused = false, timer_remaining_seconds = null,
        eliminated_options = '{}', lifeline_kind = null, lifeline_team_id = null,
        lifeline_active = false, lifeline_timer_end = null, lifeline_poll_results = null,
        last_result = null, updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
end; $$;

-- 3. Admin ends the active round — clears the header, leaves picking the
-- next round and clicking START ROUND to the admin (no auto-advance).
create or replace function public.end_round(p_session_id uuid, p_round_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  update public.quiz_rounds set status = 'DONE' where id = p_round_id;

  update public.quiz_session
    set current_question_id = null, state = 'WAITING',
        active_round_name = null, active_round_no = null, active_round_description = null,
        timer_end = null, timer_paused = false, timer_remaining_seconds = null,
        eliminated_options = '{}', lifeline_kind = null, lifeline_team_id = null,
        lifeline_active = false, lifeline_timer_end = null, lifeline_poll_results = null,
        last_result = null, updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
end; $$;
