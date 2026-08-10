-- =====================================================================
-- SCHEMA PATCH 7 — fix SHOW LIFELINES crash
-- Run once, AFTER schema-patch-6-answer-flow.sql.
-- =====================================================================

-- Bug: `... from quiz_lifeline_definitions ... order by unlock_threshold`
-- with jsonb_agg() and no GROUP BY is invalid — ORDER BY on an aggregate
-- query must be INSIDE the aggregate call, not after the FROM clause.
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
           'unlock_threshold', unlock_threshold, 'revive_threshold', revive_threshold)
           order by unlock_threshold), '[]'::jsonb)
    into v_items
    from public.quiz_lifeline_definitions where event_id = v_event_id;

  update public.quiz_session
    set state = 'INTRO_CARD', intro_content = jsonb_build_object('kind','LIFELINES','items', v_items), updated_at = now()
    where id = p_session_id
    returning * into v_session;

  return v_session;
end;
$$;
