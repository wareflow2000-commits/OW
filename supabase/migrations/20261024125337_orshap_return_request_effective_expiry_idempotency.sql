-- ORSHAP WMS v13.9.58
-- Preserve inferred batch expiry for supplier-return retries while requiring exact
-- expiry equality for other return types. Notes remain part of the idempotency key.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text)'::regprocedure;
  v_def text;
  v_old text := 'AND tl.expiry_date IS NOT DISTINCT FROM p_expiry_date AND COALESCE(tl.notes, '''') IS NOT DISTINCT FROM COALESCE(p_notes, ''''))';
  v_new text := 'AND tl.expiry_date IS NOT DISTINCT FROM CASE WHEN v_type = ''RETURN_TO_SUPPLIER'' THEN COALESCE(p_expiry_date, (SELECT s.expiry_date FROM public.stock s WHERE s.item_id=p_item_id AND s.shelf_id=p_shelf_id AND s.batch_no=COALESCE(p_batch_no, '''') AND s.administrative_department_id IS NOT DISTINCT FROM v_owner)) ELSE p_expiry_date END AND COALESCE(tl.notes, '''') IS NOT DISTINCT FROM COALESCE(p_notes, ''''))';
BEGIN
  v_def := pg_get_functiondef(v_sig);
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'Expected strict return expiry guard not found; migration aborted';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  IF position(v_new IN v_def) = 0 THEN
    RAISE EXCEPTION 'Effective expiry guard verification failed; migration aborted';
  END IF;
  EXECUTE v_def;
END;
$migration$;
