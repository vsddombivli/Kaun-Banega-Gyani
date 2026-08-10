-- =====================================================================
-- SCHEMA PATCH 5 — Round type toggles + plain timed-question flow
-- Run once in Supabase SQL Editor, AFTER schema-patch-4-....sql.
-- =====================================================================

-- 1. Round-level flags: does this round use the buzzer, rapid fire, or
-- neither (a "simple" round — show question, run the time_limit clock,
-- admin scores manually via Quick Score Adjust)?
alter table public.quiz_rounds add column if not exists has_buzzer boolean not null default true;
alter table public.quiz_rounds add column if not exists has_rapid_fire boolean not null default false;

-- 2. Admin starts a plain countdown on the currently-displayed question
-- (no buzzer semantics — every team just watches the same clock).
create or replace function public.start_simple_timer(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
  v_seconds int;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;

  select coalesce(q.time_limit, 30) into v_seconds
    from public.quiz_session s join public.quiz_questions q on q.id = s.current_question_id
    where s.id = p_session_id;

  update public.quiz_session
    set timer_end = now() + make_interval(secs => v_seconds), updated_at = now()
    where id = p_session_id and state = 'QUESTION_DISPLAY'
    returning * into v_session;

  if v_session.id is null then
    raise exception 'Question must be showing (state=QUESTION_DISPLAY) before starting the timer';
  end if;

  return v_session;
end;
$$;

-- 3. Any client's heartbeat can request this close, same server-time-gated
-- pattern as try_close_buzzer — moves to ANSWER_REVIEW once time is really up.
create or replace function public.try_close_simple_timer(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
begin
  select * into v_session from public.quiz_session where id = p_session_id;

  if v_session.state = 'QUESTION_DISPLAY' and v_session.timer_end is not null and now() >= v_session.timer_end then
    update public.quiz_session
      set state = 'ANSWER_REVIEW', updated_at = now()
      where id = p_session_id
      returning * into v_session;
  end if;

  return v_session;
end;
$$;
