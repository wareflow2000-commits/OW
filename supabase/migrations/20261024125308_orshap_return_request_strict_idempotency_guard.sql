-- ORSHAP WMS v13.9.58
-- Strictly compare return payloads on idempotent retries:
-- expiry and line notes are part of the original request and cannot be omitted/changed.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text)'::regprocedure;
  v_def text;
  v_old_expiry text := 'AND (p_expiry_date IS NULL OR tl.expiry_date IS NOT DISTINCT FROM p_expiry_date))';
  v_new_expiry text := 'AND tl.expiry_date IS NOT DISTINCT FROM p_expiry_date AND COALESCE(tl.notes, '''') IS NOT DISTINCT FROM COALESCE(p_notes, ''''))';
  v_old_supplier text := 'OR COALESCE(v_existing.supplier,'''') IS DISTINCT FROM';
  v_new_supplier text := 'OR COALESCE(v_existing.notes,'''') IS DISTINCT FROM COALESCE(p_notes,'''')' || E'\n      ' || 'OR COALESCE(v_existing.supplier,'''') IS DISTINCT FROM';
BEGIN
  v_def := pg_get_functiondef(v_sig);
  IF position(v_old_expiry IN v_def) = 0 OR position(v_old_supplier IN v_def) = 0 THEN
    RAISE EXCEPTION 'Expected return idempotency guard not found; migration aborted';
  END IF;
  v_def := replace(v_def, v_old_expiry, v_new_expiry);
  v_def := replace(v_def, v_old_supplier, v_new_supplier);
  IF position(v_new_expiry IN v_def) = 0 OR position(v_new_supplier IN v_def) = 0 THEN
    RAISE EXCEPTION 'Return idempotency guard verification failed; migration aborted';
  END IF;
  EXECUTE v_def;
END;
$migration$;
