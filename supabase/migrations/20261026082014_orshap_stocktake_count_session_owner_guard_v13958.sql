CREATE OR REPLACE FUNCTION public.save_stocktake_count(p_line_id uuid, p_counted_qty numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_line public.stocktake_lines%ROWTYPE;
  v_session public.stocktake_sessions%ROWTYPE;
BEGIN
  IF v_user IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'Active authenticated user required' USING ERRCODE='42501';
  END IF;
  IF p_counted_qty IS NULL OR p_counted_qty < 0 OR p_counted_qty::text IN ('NaN','Infinity','-Infinity') THEN
    RAISE EXCEPTION 'Count must be a finite non-negative number';
  END IF;

  SELECT * INTO v_line
  FROM public.stocktake_lines
  WHERE id = p_line_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Line not found';
  END IF;

  SELECT * INTO v_session
  FROM public.stocktake_sessions
  WHERE id = v_line.session_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Stocktake session not found';
  END IF;

  IF v_session.status <> 'IN_PROGRESS'
     OR v_session.review_status NOT IN ('DRAFT','REJECTED')
     OR COALESCE(v_line.is_settled, false) THEN
    RAISE EXCEPTION 'Session is locked';
  END IF;

  IF NOT public.current_user_has_permission('action:stocktake:count')
     AND NOT public.current_user_has_permission('action:stocktake:start') THEN
    RAISE EXCEPTION 'Count permission required' USING ERRCODE='42501';
  END IF;

  -- SECURITY DEFINER bypasses table RLS, so explicitly enforce the same owner/manager rule.
  IF v_session.created_by IS DISTINCT FROM v_user
     AND NOT public.current_user_is_manager() THEN
    RAISE EXCEPTION 'Only the stocktake creator or a manager may count this session'
      USING ERRCODE='42501';
  END IF;

  IF NOT public.current_user_can_access_warehouse(v_session.warehouse_id) THEN
    RAISE EXCEPTION 'Warehouse not assigned' USING ERRCODE='42501';
  END IF;

  UPDATE public.stocktake_lines
  SET counted_qty = p_counted_qty
  WHERE id = p_line_id;

  RETURN jsonb_build_object('success', true, 'line_id', p_line_id, 'counted_qty', p_counted_qty);
END;
$function$;
