-- Ensure a repeated transfer-order ID cannot silently change a line's expiry date.
-- Preserve all other existing transfer-order behavior.
DO $migration$
DECLARE
  v_def text;
  v_old text := $old$
            OR st.batch_no IS DISTINCT FROM COALESCE(j.line->>'batch_no','')
            OR st.source_shelf_id IS DISTINCT FROM NULLIF(j.line->>'source_shelf_id','')::uuid
            OR st.destination_shelf_id IS DISTINCT FROM NULLIF(j.line->>'destination_shelf_id','')::uuid
$old$;
  v_new text := $new$
            OR st.batch_no IS DISTINCT FROM COALESCE(j.line->>'batch_no','')
            OR st.expiry_date IS DISTINCT FROM NULLIF(j.line->>'expiry_date','')::date
            OR st.source_shelf_id IS DISTINCT FROM NULLIF(j.line->>'source_shelf_id','')::uuid
            OR st.destination_shelf_id IS DISTINCT FROM NULLIF(j.line->>'destination_shelf_id','')::uuid
$new$;
BEGIN
  SELECT pg_get_functiondef('public.dispatch_stock_transfer_order_v2(uuid,text,uuid,uuid,jsonb,text)'::regprocedure)
    INTO v_def;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'Expected transfer-order idempotency comparison was not found; migration aborted';
  END IF;
  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'Expiry date already included in idempotency comparison';
    RETURN;
  END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END
$migration$;
