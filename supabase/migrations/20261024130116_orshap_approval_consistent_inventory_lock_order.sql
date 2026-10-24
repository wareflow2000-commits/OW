-- ORSHAP WMS v13.9.58
-- Acquire transaction-line locks in inventory-key order before touching stock rows.
-- This reduces avoidable deadlocks between concurrent vouchers with reversed line order.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.approve_transaction(uuid)'::regprocedure;
  v_def text;
  v_old text := E'WHERE tl.transaction_id = p_transaction_id\n    ORDER BY tl.id\n    FOR UPDATE';
  v_new text := E'WHERE tl.transaction_id = p_transaction_id\n    ORDER BY tl.item_id, tl.shelf_id, COALESCE(tl.batch_no, ''''), tl.administrative_department_id NULLS FIRST, tl.id\n    FOR UPDATE';
BEGIN
  v_def := pg_get_functiondef(v_sig);
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'Expected approval line-lock ordering not found; migration aborted';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  IF position(v_new IN v_def) = 0 THEN
    RAISE EXCEPTION 'Approval lock ordering verification failed; migration aborted';
  END IF;
  EXECUTE v_def;
END;
$migration$;
