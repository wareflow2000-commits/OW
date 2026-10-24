CREATE OR REPLACE FUNCTION public.create_stocktake_session_with_lines(
  p_warehouse_id uuid,
  p_storage_area_id uuid DEFAULT NULL::uuid,
  p_stocktake_type text DEFAULT 'CYCLE'::text,
  p_count_mode text DEFAULT 'ANNOUNCED'::text,
  p_notes text DEFAULT NULL::text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_session_id uuid;
  v_count integer;
  v_area public.storage_areas%ROWTYPE;
  v_assigned uuid[];
BEGIN
  IF v_user_id IS NULL OR NOT public.current_user_is_active() THEN RAISE EXCEPTION 'An active authenticated user is required'; END IF;
  IF NOT public.current_user_has_permission('action:stocktake:start') THEN RAISE EXCEPTION 'You do not have permission to start stocktake sessions'; END IF;
  IF p_warehouse_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.warehouses WHERE id=p_warehouse_id) THEN RAISE EXCEPTION 'A valid warehouse is required'; END IF;
  SELECT assigned_warehouse_ids INTO v_assigned FROM public.profiles WHERE id=v_user_id;
  IF NOT public.current_user_is_manager() AND NOT (p_warehouse_id=ANY(COALESCE(v_assigned,ARRAY[]::uuid[]))) THEN RAISE EXCEPTION 'You cannot start a stocktake outside your assigned warehouses'; END IF;
  IF p_stocktake_type NOT IN ('FULL','CYCLE','SURPRISE','RECOUNT') THEN RAISE EXCEPTION 'Invalid stocktake type'; END IF;
  IF p_count_mode NOT IN ('ANNOUNCED','BLIND','VISIBLE') THEN RAISE EXCEPTION 'Invalid stocktake count mode'; END IF;
  IF p_storage_area_id IS NOT NULL THEN
    SELECT * INTO v_area FROM public.storage_areas a WHERE a.id=p_storage_area_id AND a.warehouse_id=p_warehouse_id AND COALESCE(a.is_active,true)=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Storage area is invalid, inactive, or belongs to another warehouse'; END IF;
  END IF;
  INSERT INTO public.stocktake_sessions (warehouse_id,storage_area_id,status,created_by,notes,stocktake_type,count_mode,scope_type)
  VALUES (p_warehouse_id,p_storage_area_id,'IN_PROGRESS',v_user_id,p_notes,p_stocktake_type,CASE WHEN p_count_mode='VISIBLE' THEN 'ANNOUNCED' ELSE p_count_mode END,CASE WHEN p_storage_area_id IS NULL THEN 'WAREHOUSE' ELSE 'STORAGE_AREA' END)
  RETURNING id INTO v_session_id;
  v_count := public.populate_stocktake_session_lines_internal(v_session_id);
  RETURN jsonb_build_object('success',true,'session_id',v_session_id,'line_count',v_count,'stocktake_type',p_stocktake_type,'count_mode',CASE WHEN p_count_mode='VISIBLE' THEN 'ANNOUNCED' ELSE p_count_mode END,'scope_type',CASE WHEN p_storage_area_id IS NULL THEN 'WAREHOUSE' ELSE 'STORAGE_AREA' END);
END;
$function$;
