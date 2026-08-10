-- =====================================================================
-- SCHEMA PATCH 4 — Lifeline definitions, on-screen intro cards, image storage
-- Run once in Supabase SQL Editor, AFTER schema-patch-3-fixes.sql.
-- =====================================================================

-- 1. Session: add a generic payload column + new state for "broadcast an
-- explainer card to the projector" (used for lifelines intro AND round
-- rules, so we don't need a new state per intro type in future).
alter table public.quiz_session add column if not exists intro_content jsonb;

alter table public.quiz_session drop constraint if exists quiz_session_state_check;
alter table public.quiz_session add constraint quiz_session_state_check check (state in (
  'WAITING','QUESTION_DISPLAY','BUZZER_OPEN','BUZZER_CLOSED','ANSWERING',
  'ANSWER_REVIEW','PASSING','AUDIENCE_POLL_OPEN','AUDIENCE_POLL_CLOSED',
  'RESULT_REVEAL','QUESTION_COMPLETE','RAPID_FIRE_ACTIVE','LEADERBOARD','INTRO_CARD'));

-- 2. Lifeline definitions — one row per lifeline type per event, replacing
-- the old ad-hoc quiz_lifeline_milestones for unlock/revive purposes.
-- (quiz_lifeline_milestones is left in place but no longer read by
-- check_lifeline_milestones — safe to ignore or drop later.)
create table if not exists public.quiz_lifeline_definitions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.quiz_events(id) on delete cascade,
  lifeline_type text not null check (lifeline_type in ('FIFTY_FIFTY','AUDIENCE','EXPERT','TEAM_ADVICE')),
  description text,
  unlock_threshold int not null default 0,
  revive_threshold int, -- null = never auto-revives once used
  created_at timestamptz default now(),
  unique(event_id, lifeline_type)
);
alter table public.quiz_lifeline_definitions enable row level security;

drop policy if exists p_read_lifeline_defs on public.quiz_lifeline_definitions;
create policy p_read_lifeline_defs on public.quiz_lifeline_definitions for select using (true);
drop policy if exists p_admin_all_lifeline_defs on public.quiz_lifeline_definitions;
create policy p_admin_all_lifeline_defs on public.quiz_lifeline_definitions for all
  using (public.is_admin()) with check (public.is_admin());

-- 3. Replace check_lifeline_milestones to read from the new definitions
-- table: auto-unlocks at unlock_threshold, auto-revives a USED lifeline
-- at revive_threshold (if set).
create or replace function public.check_lifeline_milestones(p_team_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_points int;
  v_event_id uuid;
  d record;
begin
  select points, event_id into v_points, v_event_id from public.quiz_teams where id = p_team_id;

  for d in select * from public.quiz_lifeline_definitions where event_id = v_event_id loop
    if v_points >= d.unlock_threshold then
      insert into public.quiz_lifelines (team_id, lifeline_type, status, unlocked_at)
      values (p_team_id, d.lifeline_type, 'AVAILABLE', now())
      on conflict (team_id, lifeline_type) do update
        set status = 'AVAILABLE', unlocked_at = coalesce(public.quiz_lifelines.unlocked_at, now())
        where public.quiz_lifelines.status = 'LOCKED';
    end if;

    if d.revive_threshold is not null and v_points >= d.revive_threshold then
      update public.quiz_lifelines set status = 'AVAILABLE', revived_at = now()
        where team_id = p_team_id and lifeline_type = d.lifeline_type and status = 'USED';
    end if;
  end loop;
end;
$$;

-- 4. Admin broadcasts the lifelines explainer to the projector
create or replace function public.show_lifelines_intro(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
  v_event_id uuid;
  v_items jsonb;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;

  select event_id into v_event_id from public.quiz_session where id = p_session_id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'type', lifeline_type, 'description', description,
           'unlock_threshold', unlock_threshold, 'revive_threshold', revive_threshold)), '[]'::jsonb)
    into v_items
    from public.quiz_lifeline_definitions where event_id = v_event_id order by unlock_threshold;

  update public.quiz_session
    set state = 'INTRO_CARD', intro_content = jsonb_build_object('kind','LIFELINES','items', v_items), updated_at = now()
    where id = p_session_id
    returning * into v_session;

  return v_session;
end;
$$;

-- 5. Admin broadcasts a round's rules/description to the projector
create or replace function public.show_round_intro(p_session_id uuid, p_round_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
  v_round public.quiz_rounds;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;

  select * into v_round from public.quiz_rounds where id = p_round_id;

  update public.quiz_session
    set state = 'INTRO_CARD',
        intro_content = jsonb_build_object('kind','ROUND', 'round_no', v_round.round_no,
                          'round_name', v_round.round_name, 'description', v_round.description),
        updated_at = now()
    where id = p_session_id
    returning * into v_session;

  return v_session;
end;
$$;

-- 6. Admin dismisses whatever intro card is showing
create or replace function public.dismiss_intro(p_session_id uuid)
returns public.quiz_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.quiz_session;
begin
  if not public.is_admin() then raise exception 'Admin only'; end if;
  update public.quiz_session set state = 'WAITING', intro_content = null, updated_at = now()
    where id = p_session_id returning * into v_session;
  return v_session;
end;
$$;

-- 7. Storage bucket for question images — uploaded as-is, no resizing.
-- (Compression/blur avoidance is a client-side concern: the admin panel
-- upload code must NOT pass the file through a <canvas> resize step —
-- see admin.html delta. Supabase Storage itself never re-encodes files.)
insert into storage.buckets (id, name, public)
  values ('question-images', 'question-images', true)
  on conflict (id) do nothing;

drop policy if exists p_public_read_question_images on storage.objects;
create policy p_public_read_question_images on storage.objects for select
  using (bucket_id = 'question-images');

drop policy if exists p_admin_write_question_images on storage.objects;
create policy p_admin_write_question_images on storage.objects for insert
  with check (bucket_id = 'question-images' and public.is_admin());

drop policy if exists p_admin_delete_question_images on storage.objects;
create policy p_admin_delete_question_images on storage.objects for delete
  using (bucket_id = 'question-images' and public.is_admin());

-- 8. Make sure INTRO_CARD-relevant tables are live over realtime
alter publication supabase_realtime add table public.quiz_lifeline_definitions;
