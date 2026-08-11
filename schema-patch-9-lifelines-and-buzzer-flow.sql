-- =====================================================================
-- SCHEMA PATCH 9 — simplified buzzer flow + mid-question lifelines
-- Run once, AFTER schema-patch-8-pause-resume-autoreveal.sql.
-- =====================================================================

-- 1. Round: separate buzz-in window from answer window. New rounds should
-- set buzzer_window_seconds to ~15 (buzz-in) going forward.
alter table public.quiz_rounds add column if not exists answer_window_seconds int not null default 30;
alter table public.quiz_rounds alter column buzzer_window_seconds set default 15;

-- 2. Session: lifeline sub-state, 50-50 eliminations, lifeline sub-timer.
alter table public.quiz_session add column if not exists eliminated_options text[] not null default '{}';
alter table public.quiz_session add column if not exists lifeline_kind text
  check (lifeline_kind in ('FIFTY_FIFTY','AUDIENCE','EXPERT','TEAM_ADVICE') or lifeline_kind is null);
alter table public.quiz_session add column if not exists lifeline_team_id uuid references public.quiz_teams(id);
alter table public.quiz_session add column if not exists lifeline_active boolean not null default false;
alter table public.quiz_session add column if not exists lifeline_timer_end timestamptz;
alter table public.quiz_session add column if not exists lifeline_poll_results jsonb;

-- 3. One lifeline per team per question, regardless of type.
create table if not exists public.quiz_question_lifeline_uses (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.quiz_questions(id) on delete cascade,
  team_id uuid not null references public.quiz_teams(id) on delete cascade,
  lifeline_type text not null,
  used_at timestamptz default now(),
  unique(question_id, team_id)
);
alter table public.quiz_question_lifeline_uses enable row level security;
drop policy if exists p_admin_all_qllu on public.quiz_question_lifeline_uses;
create policy p_admin_all_qllu on public.quiz_question_lifeline_uses for all
  using (public.is_admin()) with check (public.is_admin());

-- 4. push_question: reset all lifeline sub-state on every new question.
create or replace function public.push_question(p_session_id uuid, p_question_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare
  v_session public.quiz_session; v_round public.quiz_rounds; v_time_limit int;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;

  select r.* into v_round
    from public.quiz_questions q join public.quiz_rounds r on r.id = q.round_id
    where q.id = p_question_id;
  select time_limit into v_time_limit from public.quiz_questions where id = p_question_id;

  update public.quiz_session
    set current_question_id = p_question_id, current_round_id = v_round.id,
        state = 'QUESTION_DISPLAY', buzzer_open = false, audience_poll_open = false,
        answering_team_id = null, answering_position = null,
        timer_paused = false, timer_remaining_seconds = null,
        timer_end = case when not v_round.has_buzzer and not v_round.has_rapid_fire
                      then now() + make_interval(secs => greatest(coalesce(v_time_limit,30),5))
                      else null end,
        eliminated_options = '{}', lifeline_kind = null, lifeline_team_id = null,
        lifeline_active = false, lifeline_timer_end = null, lifeline_poll_results = null,
        last_result = null, updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
end; $$;

-- 5. resume_timer: resuming also always clears whatever lifeline was
-- active — resuming IS the "lifeline is done" signal.
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
        timer_paused = false, timer_remaining_seconds = null,
        eliminated_options = '{}', lifeline_kind = null, lifeline_team_id = null,
        lifeline_active = false, lifeline_timer_end = null, lifeline_poll_results = null,
        updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
end; $$;

-- 6. Admin activates a lifeline for a team mid-question. Pauses the main
-- timer (if running), enforces one-per-team-per-question, enforces
-- lifelines only apply in simple (no-buzzer, no-rapid-fire) rounds.
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

  -- one lifeline per team per question (any type)
  insert into public.quiz_question_lifeline_uses (question_id, team_id, lifeline_type)
    values (v_session.current_question_id, p_team_id, p_lifeline_type);
  -- unique_violation caught below if already used one this question

  update public.quiz_lifelines set status = 'USED', used_at = now()
    where team_id = p_team_id and lifeline_type = p_lifeline_type and status = 'AVAILABLE';
  if not found then
    raise exception 'This lifeline is not available for this team';
  end if;

  -- pause the main timer if it's running and not already paused
  if v_session.timer_end is not null and not v_session.timer_paused then
    v_remaining := greatest(extract(epoch from (v_session.timer_end - now()))::int, 0);
  else
    v_remaining := v_session.timer_remaining_seconds;
  end if;

  if p_lifeline_type = 'FIFTY_FIFTY' then
    select array(
      select unnest(array['A','B','C','D']) except select v_question.correct_option
      order by random() limit 2
    ) into v_eliminated;
  else
    v_eliminated := '{}';
  end if;

  update public.quiz_session
    set timer_paused = true, timer_remaining_seconds = v_remaining,
        lifeline_kind = p_lifeline_type, lifeline_team_id = p_team_id, lifeline_active = true,
        eliminated_options = v_eliminated,
        lifeline_timer_end = case when p_lifeline_type in ('AUDIENCE','EXPERT','TEAM_ADVICE')
                                then now() + interval '30 seconds' else null end,
        lifeline_poll_results = null,
        updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
exception
  when unique_violation then
    raise exception 'This team already used a lifeline on this question';
end; $$;

-- 7. Server-time-gated close of the lifeline sub-timer (audience-poll-as-
-- lifeline gets its tally computed and frozen; expert/team-advice just
-- stop counting). Panel stays visible until admin clicks RESUME.
create or replace function public.try_close_lifeline_subtimer(p_session_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session; v_results jsonb;
begin
  select * into v_session from public.quiz_session where id = p_session_id;

  if v_session.lifeline_active and v_session.lifeline_timer_end is not null
     and now() >= v_session.lifeline_timer_end then

    if v_session.lifeline_kind = 'AUDIENCE' and v_session.lifeline_poll_results is null then
      select jsonb_agg(jsonb_build_object('option', option, 'votes', votes, 'pct', pct))
        into v_results from public.get_audience_results(v_session.current_question_id);
    end if;

    update public.quiz_session
      set lifeline_timer_end = null,
          lifeline_poll_results = coalesce(v_results, v_session.lifeline_poll_results),
          updated_at = now()
      where id = p_session_id returning * into v_session;
  end if;

  return v_session;
end; $$;

-- 8. Audience votes now also accepted during a lifeline-triggered mini-poll
-- (session.state stays QUESTION_DISPLAY/paused throughout — the ordinary
-- AUDIENCE_POLL_OPEN path is untouched for full audience-poll rounds).
create or replace function public.submit_vote(p_session_id uuid, p_session_device_id text, p_option text)
returns public.quiz_audience_votes
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session; v_row public.quiz_audience_votes;
begin
  select * into v_session from public.quiz_session where id = p_session_id;

  if v_session.state = 'AUDIENCE_POLL_OPEN' and v_session.audience_poll_open then
    if now() >= v_session.timer_end then raise exception 'Voting window has closed'; end if;
  elsif v_session.lifeline_kind = 'AUDIENCE' and v_session.lifeline_active
        and v_session.lifeline_timer_end is not null and now() < v_session.lifeline_timer_end then
    null; -- lifeline mini-poll is open, proceed
  else
    raise exception 'Audience poll is not open';
  end if;

  insert into public.quiz_audience_votes (question_id, session_id, option)
    values (v_session.current_question_id, p_session_device_id, p_option)
    returning * into v_row;
  return v_row;
exception
  when unique_violation then raise exception 'You already voted on this question';
end; $$;

-- 9. Buzzer flow, simplified: buzz-in window -> admin starts a SEPARATE
-- answer window for whoever buzzed first -> correct/wrong, no passing.
create or replace function public.start_answer_timer(p_session_id uuid)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session; v_round public.quiz_rounds; v_first_team uuid;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  select * into v_session from public.quiz_session where id = p_session_id;
  select * into v_round from public.quiz_rounds where id = v_session.current_round_id;

  select team_id into v_first_team from public.quiz_buzzers
    where question_id = v_session.current_question_id order by sequence_no asc limit 1;
  if v_first_team is null then raise exception 'No team buzzed in'; end if;

  update public.quiz_session
    set state = 'ANSWERING', answering_team_id = v_first_team, answering_position = 1,
        timer_end = now() + make_interval(secs => greatest(coalesce(v_round.answer_window_seconds,30),5)),
        timer_paused = false, timer_remaining_seconds = null, updated_at = now()
    where id = p_session_id returning * into v_session;

  return v_session;
end; $$;

create or replace function public.mark_buzzer_answer(p_session_id uuid, p_correct boolean)
returns public.quiz_session
language plpgsql security definer set search_path = public as $$
declare v_session public.quiz_session; v_round public.quiz_rounds; v_points int;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  select * into v_session from public.quiz_session where id = p_session_id;
  select * into v_round from public.quiz_rounds where id = v_session.current_round_id;

  if v_session.answering_team_id is null then raise exception 'No team is currently answering'; end if;

  v_points := case when p_correct then v_round.first_correct_points else v_round.first_wrong_points end;

  update public.quiz_teams set points = points + v_points, updated_at = now() where id = v_session.answering_team_id;
  insert into public.quiz_scores (team_id, question_id, points_change, reason, admin_id)
    values (v_session.answering_team_id, v_session.current_question_id, v_points,
            case when p_correct then 'Buzzer correct' else 'Buzzer wrong' end, auth.uid());

  update public.quiz_session
    set last_result = jsonb_build_object('team_id', v_session.answering_team_id, 'correct', p_correct, 'points', v_points),
        state = 'QUESTION_COMPLETE', answering_team_id = null, answering_position = null,
        timer_end = null, updated_at = now()
    where id = p_session_id returning * into v_session;

  perform public.check_lifeline_milestones(v_session.answering_team_id);
  return v_session;
end; $$;
