-- An inter-warehouse order may acquire a destination shelf after physical receipt.
-- A retry of the original order payload (which intentionally left the shelf blank) must still replay.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.dispatch_stock_transfer_order_v2(uuid,text,uuid,uuid,jsonb,text)'::regprocedure;
  v_def text;
  v_old text := 'OR st.destination_shelf_id IS DISTINCT FROM NULLIF(j.line->>''destination_shelf_id'','''')::uuid';
  v_new text := 'OR (NULLIF(j.line->>''destination_shelf_id'','''') IS NOT NULL AND st.destination_shelf_id IS DISTINCT FROM NULLIF(j.line->>''destination_shelf_id'','''')::uuid)';
BEGIN
  v_def:=pg_get_functiondef(v_sig);
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transfer order destination-shelf retry check not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  IF position(v_new IN v_def)=0 THEN RAISE EXCEPTION 'Transfer order destination-shelf retry check verification failed'; END IF;
  EXECUTE v_def;
END;
$migration$;
