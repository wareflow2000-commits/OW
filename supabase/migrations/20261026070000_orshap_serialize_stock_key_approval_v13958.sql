-- ORSHAP WMS v13.9.58: serialize stock-key posting even when the stock row does not yet exist.
-- This keeps balance_before/balance_after correct for concurrent inbound approvals.
BEGIN;
DO $patch$
DECLARE
  v_body text;
  v_new_body text;
  v_def text;
  v_new_def text;
  v_anchor text := $a$    v_old_qty := 0;
    SELECT s.quantity INTO v_old_qty
    FROM public.stock s
    WHERE s.item_id = v_rec.item_id
      AND s.shelf_id = v_rec.shelf_id
      AND s.batch_no = COALESCE(v_rec.batch_no, '')
      AND s.administrative_department_id IS NOT DISTINCT FROM v_rec.administrative_department_id
    FOR UPDATE;
    v_old_qty := COALESCE(v_old_qty, 0);$a$;
  v_replacement text := $b$    -- Lock the canonical stock key before reading it. FOR UPDATE alone cannot lock
    -- a missing row, so concurrent inbound approvals could otherwise log stale balances.
    PERFORM pg_advisory_xact_lock(hashtextextended(
      v_rec.item_id::text || ':' || v_rec.shelf_id::text || ':' ||
      COALESCE(v_rec.batch_no, '') || ':' || COALESCE(v_rec.administrative_department_id::text, ''),
      0
    ));
    v_old_qty := 0;
    SELECT s.quantity INTO v_old_qty
    FROM public.stock s
    WHERE s.item_id = v_rec.item_id
      AND s.shelf_id = v_rec.shelf_id
      AND s.batch_no = COALESCE(v_rec.batch_no, '')
      AND s.administrative_department_id IS NOT DISTINCT FROM v_rec.administrative_department_id
    FOR UPDATE;
    v_old_qty := COALESCE(v_old_qty, 0);$b$;
  v_count integer;
BEGIN
  SELECT p.prosrc INTO v_body
  FROM pg_proc p
  WHERE p.oid = 'public.approve_transaction(uuid)'::regprocedure;

  v_count := (length(v_body) - length(replace(v_body, v_anchor, ''))) / length(v_anchor);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one stock-key read anchor in approve_transaction, found %', v_count;
  END IF;
  IF position('pg_advisory_xact_lock(hashtextextended' in v_body) > 0 THEN
    RAISE EXCEPTION 'approve_transaction already has a stock-key advisory lock; inspect before reapplying';
  END IF;

  v_new_body := replace(v_body, v_anchor, v_replacement);
  v_def := pg_get_functiondef('public.approve_transaction(uuid)'::regprocedure);
  v_new_def := replace(v_def, v_body, v_new_body);
  IF v_new_def = v_def THEN
    RAISE EXCEPTION 'Could not reconstruct approve_transaction definition';
  END IF;
  EXECUTE v_new_def;
END
$patch$;
COMMIT;
