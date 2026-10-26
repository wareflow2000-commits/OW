CREATE OR REPLACE FUNCTION public.populate_stocktake_session_lines(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_session public.stocktake_sessions%ROWTYPE;
  v_count integer;
BEGIN
  IF v_user_id IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'An active authenticated user is required' USING ERRCODE='42501';
  END IF;
  IF NOT public.current_user_has_permission('action:stocktake:start') THEN
    RAISE EXCEPTION 'You do not have permission to populate stocktake sessions' USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_session FROM public.stocktake_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stocktake session not found'; END IF;
  IF v_session.created_by IS DISTINCT FROM v_user_id AND NOT public.current_user_is_manager() THEN
    RAISE EXCEPTION 'Only the stocktake creator or a manager may populate this session' USING ERRCODE='42501';
  END IF;
  IF v_session.status <> 'IN_PROGRESS' OR v_session.review_status NOT IN ('DRAFT','REJECTED') THEN
    RAISE EXCEPTION 'Only an editable in-progress session can be populated';
  END IF;
  IF NOT public.current_user_can_access_warehouse(v_session.warehouse_id) THEN
    RAISE EXCEPTION 'You cannot populate a session outside your assigned warehouses' USING ERRCODE='42501';
  END IF;
  v_count := public.populate_stocktake_session_lines_internal(p_session_id);
  RETURN jsonb_build_object('success', true, 'session_id', p_session_id, 'line_count', v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_stocktake_for_review(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_s public.stocktake_sessions%ROWTYPE;
  v_total integer;
  v_counted integer;
BEGIN
  IF v_user IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'Active authenticated user required' USING ERRCODE='42501';
  END IF;
  IF NOT public.current_user_has_permission('action:stocktake:submit')
     AND NOT public.current_user_has_permission('action:stocktake:start') THEN
    RAISE EXCEPTION 'Submit permission required' USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_s FROM public.stocktake_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR v_s.status <> 'IN_PROGRESS' THEN RAISE EXCEPTION 'Only in-progress sessions can be submitted'; END IF;
  IF v_s.review_status NOT IN ('DRAFT','REJECTED') THEN RAISE EXCEPTION 'Session already submitted'; END IF;
  IF v_s.created_by IS DISTINCT FROM v_user AND NOT public.current_user_is_manager() THEN
    RAISE EXCEPTION 'Only the stocktake creator or a manager may submit this session' USING ERRCODE='42501';
  END IF;
  IF NOT public.current_user_can_access_warehouse(v_s.warehouse_id) THEN
    RAISE EXCEPTION 'Warehouse not assigned' USING ERRCODE='42501';
  END IF;
  SELECT count(*), count(*) FILTER (WHERE counted_qty IS NOT NULL)
  INTO v_total, v_counted FROM public.stocktake_lines WHERE session_id = p_session_id;
  IF v_total = 0 OR v_total <> v_counted THEN RAISE EXCEPTION 'All stocktake lines must be counted before submission'; END IF;
  UPDATE public.stocktake_sessions
  SET review_status = 'PENDING_REVIEW', submitted_by = v_user, submitted_at = now(),
      reviewed_by = NULL, reviewed_at = NULL, review_comment = NULL
  WHERE id = p_session_id;
  RETURN jsonb_build_object('success', true, 'session_id', p_session_id,
    'review_status', 'PENDING_REVIEW', 'lines_counted', v_counted);
END;
$function$;
