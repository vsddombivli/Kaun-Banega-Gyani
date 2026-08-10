-- =====================================================================
-- SCHEMA PATCH 8 — auto-start timer, pause/resume, robust audience reveal
-- Run once, AFTER schema-patch-7-fix-lifelines-crash.sql.
-- =====================================================================

-- 1. Pause/resume state
alter table public.quiz_session add column if not exists timer_paused boolean not null default false;
alter table public.quiz_session add column if not exists timer_remaining_seconds int;

-- 2. push_question: for a "simple" round (no buzzer, no rapid fire), start
-- the countdown immediately using the question's time_limit — no separate
-- START TIMER click needed. Buzzer/rapid-fire rounds are unaffected.
create or replace function public.push_question(p_session_id uuid, p_question_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare
  v_session public.quiz_session;
  v_round public.quiz_rounds;
  v_time_limit int;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;

  select r.*, q.time_limit into v_round, v_time_limit
    from public.quiz_questions q join public.quiz_rounds r on r.id = q.round_id
    where q.id = p_question_id;

  update public.quiz_session
    set current_question_id = p_question_id,
        current_round_id = v_round.id,
        state = 'QUESTION_DISPLAY',
        buzzer_open = false,
        audience_poll_open = false,
        answering_team_id = null,
        answering_position = null,
        timer_paused = false,
        timer_remaining_seconds = null,
        timer_end = case when not v_round.has_buzzer and not v_round.has_rapid_fire
                      then now() + make_interval(secs => greatest(coalesce(v_time_limit,30),5))
                      else null end,
        last_result = null,
        updated_at = now()
    where id = p_session_id
    returning * into v_session;

  return v_session;
end; $$;

-- 3. Pause any running timer (buzzer window, audience poll, or simple-round
-- clock) — freezes the displayed remaining time, admin can resume later.
-- This is what lets a team use a lifeline mid-question without the clock
-- running out from under them.
create or replace function public.pause_timer(p_session_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare
  v_session public.quiz_session; v_remaining int;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  select * into v_session from public.quiz_session where id = p_session_id;

  if v_session.timer_end is null or v_session.timer_paused then
    raise exception 'No running timer to pause';
  end if;

  v_remaining := greatest(extract(epoch from (v_session.timer_end - now()))::int, 0);

  update public.quiz_session
    set timer_paused = true, timer_remaining_seconds = v_remaining, updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
end; $$;

-- 4. Resume a paused timer — recomputes timer_end from the frozen remaining time.
create or replace function public.resume_timer(p_session_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  select * into v_session from public.quiz_session where id = p_session_id;

  if not v_session.timer_paused then raise exception 'Timer is not paused'; end if;

  update public.quiz_session
    set timer_end = now() + make_interval(secs => greatest(coalesce(v_session.timer_remaining_seconds,0),0)),
        timer_paused = false, timer_remaining_seconds = null, updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
end; $$;

-- 5. Guard every auto-close function against firing while paused (defense
-- in depth — clients should already stop calling these while paused).
create or replace function public.try_close_buzzer(p_session_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session;
begin
  select * into v_session from public.quiz_session where id = p_session_id;
  if v_session.state = 'BUZZER_OPEN' and not v_session.timer_paused and now() >= v_session.timer_end then
    update public.quiz_session set state = 'BUZZER_CLOSED', buzzer_open = false, updated_at = now()
      where id = p_session_id returning * into v_session;
  end if;
  return v_session;
end; $$;

create or replace function public.try_close_simple_timer(p_session_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session;
begin
  select * into v_session from public.quiz_session where id = p_session_id;
  if v_session.state = 'QUESTION_DISPLAY' and v_session.timer_end is not null
     and not v_session.timer_paused and now() >= v_session.timer_end then
    update public.quiz_session set state = 'ANSWER_REVIEW', updated_at = now()
      where id = p_session_id returning * into v_session;
  end if;
  return v_session;
end; $$;

-- 6. try_close_audience_poll now goes STRAIGHT to RESULT_REVEAL with the
-- vote tally embedded in last_result — no separate AUDIENCE_POLL_CLOSED
-- limbo state, and no dependence on the admin remembering to click
-- REVEAL ANSWER or on the question's question_type field being set
-- correctly. last_result.kind = 'AUDIENCE_POLL' is the reliable marker
-- screen.html/audience.html use to render results.
create or replace function public.try_close_audience_poll(p_session_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare
  v_session public.quiz_session;
  v_results jsonb;
begin
  select * into v_session from public.quiz_session where id = p_session_id;

  if v_session.state = 'AUDIENCE_POLL_OPEN' and not v_session.timer_paused and now() >= v_session.timer_end then
    select jsonb_agg(jsonb_build_object('option', option, 'votes', votes, 'pct', pct))
      into v_results
      from public.get_audience_results(v_session.current_question_id);

    update public.quiz_session
      set state = 'RESULT_REVEAL', audience_poll_open = false,
          last_result = jsonb_build_object('kind','AUDIENCE_POLL','results', coalesce(v_results,'[]'::jsonb)),
          updated_at = now()
      where id = p_session_id returning * into v_session;
  end if;

  return v_session;
end; $$;
