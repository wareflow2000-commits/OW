-- ORSHAP WMS v13.9.58
-- A return retry may only replay the exact single-line request created by this user
-- in a warehouse they are still authorized to access.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef(v_sig);
  v_old := 'IF v_existing.transaction_type IS DISTINCT FROM v_type';
  v_new := 'IF v_existing.created_by IS DISTINCT FROM v_user OR v_existing.transaction_type IS DISTINCT FROM v_type';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Return retry identity guard not found'; END IF;
  v_def := replace(v_def,v_old,v_new);
  v_old := 'OR NOT EXISTS (SELECT 1 FROM public.transaction_lines tl';
  v_new := 'OR (SELECT count(*) FROM public.transaction_lines all_lines WHERE all_lines.transaction_id=p_return_id) <> 1' || E'\n      ' ||
           'OR NOT EXISTS (SELECT 1 FROM public.shelves sh WHERE sh.id=p_shelf_id AND sh.warehouse_id=v_existing.warehouse_id AND (v_profile.role IN (''SUPER_ADMIN'',''ADMIN'',''MANAGER'') OR (cardinality(COALESCE(v_profile.assigned_warehouse_ids, ARRAY[]::uuid[])) > 0 AND sh.warehouse_id=ANY(v_profile.assigned_warehouse_ids))))' || E'\n      ' ||
           'OR NOT EXISTS (SELECT 1 FROM public.transaction_lines tl';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Return retry line guard not found'; END IF;
  v_def := replace(v_def,v_old,v_new);
  IF position('v_existing.created_by IS DISTINCT FROM v_user' IN v_def)=0
     OR position('all_lines.transaction_id=p_return_id) <> 1' IN v_def)=0
     OR position('sh.warehouse_id=v_existing.warehouse_id' IN v_def)=0 THEN
    RAISE EXCEPTION 'Return retry guard verification failed';
  END IF;
  EXECUTE v_def;
END;
$migration$;
