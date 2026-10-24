-- ORSHAP WMS v13.9.58
-- Prevent transfer-order retries from replaying another user's order or silently
-- accepting changed explicit per-line transfer IDs.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.dispatch_stock_transfer_order_v2(uuid,text,uuid,uuid,jsonb,text)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef(v_sig);
  v_old := 'IF v_existing.reference_no IS DISTINCT FROM btrim(p_reference_no)';
  v_new := 'IF v_existing.created_by IS DISTINCT FROM v_user OR v_existing.reference_no IS DISTINCT FROM btrim(p_reference_no)';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transfer order creator/idempotency guard not found'; END IF;
  v_def := replace(v_def,v_old,v_new);

  v_old := E'OR st.destination_shelf_id IS DISTINCT FROM NULLIF(j.line->>''destination_shelf_id'','''')::uuid\n       ) THEN RAISE EXCEPTION';
  v_new := E'OR st.destination_shelf_id IS DISTINCT FROM NULLIF(j.line->>''destination_shelf_id'','''')::uuid\n            OR (NULLIF(j.line->>''transfer_id'','''') IS NOT NULL AND st.id IS DISTINCT FROM NULLIF(j.line->>''transfer_id'','''')::uuid)\n       ) THEN RAISE EXCEPTION';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transfer order line identity guard not found'; END IF;
  v_def := replace(v_def,v_old,v_new);

  IF position('v_existing.created_by IS DISTINCT FROM v_user' IN v_def)=0
     OR position('st.id IS DISTINCT FROM NULLIF(j.line->>''transfer_id''' IN v_def)=0 THEN
    RAISE EXCEPTION 'Transfer order idempotency guard verification failed';
  END IF;
  EXECUTE v_def;
END;
$migration$;
