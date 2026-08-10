-- =====================================================================
-- SCHEMA PATCH 6 — buzzer floor fix, manual-select MCQ flow, end-round
-- Run once, AFTER schema-patch-5-simple-rounds.sql.
-- =====================================================================

-- 1. Fix: a round accidentally saved with buzzer_window_seconds = 0 (not
-- NULL) bypassed the coalesce() default and closed instantly. Floor it.
create or replace function public.open_buzzer(p_session_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session; v_seconds int;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  select coalesce(r.buzzer_window_seconds, 30) into v_seconds
    from public.quiz_session s join public.quiz_rounds r on r.id = s.current_round_id
    where s.id = p_session_id;
  v_seconds := greatest(coalesce(v_seconds, 30), 5); -- never allow < 5s
  update public.quiz_session set state='BUZZER_OPEN', buzzer_open=true,
    timer_end = now() + make_interval(secs => v_seconds), updated_at = now()
    where id = p_session_id returning * into v_session;
  return v_session;
end; $$;

-- 2. New state for "admin has selected which team verbally answered,
-- not yet revealed"
alter table public.quiz_session drop constraint if exists quiz_session_state_check;
alter table public.quiz_session add constraint quiz_session_state_check check (state in (
  'WAITING','QUESTION_DISPLAY','BUZZER_OPEN','BUZZER_CLOSED','ANSWERING',
  'ANSWER_REVIEW','ANSWER_SELECTED','PASSING','AUDIENCE_POLL_OPEN','AUDIENCE_POLL_CLOSED',
  'RESULT_REVEAL','QUESTION_COMPLETE','RAPID_FIRE_ACTIVE','LEADERBOARD','INTRO_CARD'));

-- 3. Admin records which team verbally answered which option (simple/no-buzzer rounds)
create or replace function public.record_simple_answer(p_session_id uuid, p_team_id uuid, p_option text)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  update public.quiz_session
    set state = 'ANSWER_SELECTED', answering_team_id = p_team_id,
        last_result = jsonb_build_object('team_id', p_team_id, 'selected_option', p_option),
        updated_at = now()
    where id = p_session_id returning * into v_session;
  return v_session;
end; $$;

-- 4. reveal_result now scores a simple-round manual selection at reveal
-- time (buzzer-round results are already scored earlier by
-- mark_buzzer_answer, so this only fills in when 'correct' isn't set yet).
-- Also embeds correct_option into last_result so the public question view
-- (which hides it) can still be safely rendered post-reveal.
create or replace function public.reveal_result(p_session_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare
  v_session public.quiz_session; v_round public.quiz_rounds; v_question public.quiz_questions;
  v_correct boolean; v_points int;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  select * into v_session from public.quiz_session where id = p_session_id;
  select * into v_question from public.quiz_questions where id = v_session.current_question_id;
  select * into v_round from public.quiz_rounds where id = v_session.current_round_id;

  if v_session.last_result ? 'selected_option' and not (v_session.last_result ? 'correct') then
    v_correct := (v_session.last_result->>'selected_option') = v_question.correct_option;
    v_points := case when v_correct then v_round.first_correct_points else v_round.first_wrong_points end;

    update public.quiz_teams set points = points + v_points, updated_at = now()
      where id = (v_session.last_result->>'team_id')::uuid;
    insert into public.quiz_scores (team_id, question_id, points_change, reason, admin_id)
      values ((v_session.last_result->>'team_id')::uuid, v_question.id, v_points,
              case when v_correct then 'Correct (manual)' else 'Wrong (manual)' end, auth.uid());
    perform public.check_lifeline_milestones((v_session.last_result->>'team_id')::uuid);

    v_session.last_result := v_session.last_result || jsonb_build_object('correct', v_correct, 'points', v_points, 'correct_option', v_question.correct_option);
  else
    v_session.last_result := coalesce(v_session.last_result, '{}'::jsonb) || jsonb_build_object('correct_option', v_question.correct_option);
  end if;

  update public.quiz_session set state = 'RESULT_REVEAL', last_result = v_session.last_result, updated_at = now()
    where id = p_session_id returning * into v_session;
  return v_session;
end; $$;

-- 5. Admin ends the current round and advances to the next one, broadcasting
-- a transition card ("Round X complete — Round Y begins") to the projector.
create or replace function public.end_round_and_advance(p_session_id uuid, p_ending_round_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare
  v_session public.quiz_session; v_ending public.quiz_rounds; v_next public.quiz_rounds;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;

  update public.quiz_rounds set status = 'DONE' where id = p_ending_round_id returning * into v_ending;

  select * into v_next from public.quiz_rounds
    where event_id = v_ending.event_id and round_no > v_ending.round_no and status <> 'DONE'
    order by round_no asc limit 1;

  if v_next.id is not null then
    update public.quiz_rounds set status = 'ACTIVE' where id = v_next.id;
  end if;

  update public.quiz_session
    set state = 'INTRO_CARD', current_question_id = null, answering_team_id = null, timer_end = null,
        intro_content = jsonb_build_object('kind','ROUND_TRANSITION',
          'ended_round_name', v_ending.round_name, 'ended_round_no', v_ending.round_no,
          'next_round_name', v_next.round_name, 'next_round_no', v_next.round_no, 'next_round_description', v_next.description),
        updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
end; $$;
