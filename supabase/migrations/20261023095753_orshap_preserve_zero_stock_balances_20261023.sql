-- ORSHAP WMS v13.9.58
-- Keep zero-balance stock keys instead of deleting them during outbound posting.
-- This preserves the invariant established by maintain_stock_versions_and_retain_zero_balances.
-- Patch the current function definition narrowly so its permission, ledger, audit, and
-- transaction-state logic remains unchanged. Abort if the expected branch is not unique.
DO $migration$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  v_definition := pg_get_functiondef('public.approve_transaction(uuid)'::regprocedure);

  v_old := $old$
      IF v_new_qty = 0 THEN
        DELETE FROM public.stock
        WHERE item_id = v_rec.item_id
          AND shelf_id = v_rec.shelf_id
          AND batch_no = COALESCE(v_rec.batch_no, '');
      ELSE
$old$;

  v_new := $new$
      IF v_new_qty = 0 THEN
        UPDATE public.stock
        SET quantity = 0,
            storage_area_id = COALESCE(v_rec.storage_area_id, (SELECT sh.storage_area_id FROM public.shelves sh WHERE sh.id=v_rec.shelf_id), storage_area_id),
            updated_at = NOW()
        WHERE item_id = v_rec.item_id
          AND shelf_id = v_rec.shelf_id
          AND batch_no = COALESCE(v_rec.batch_no, '');
      ELSE
$new$;

  v_count := length(v_definition) - length(replace(v_definition, v_old, ''));
  IF v_count <> length(v_old) THEN
    RAISE EXCEPTION 'Expected exactly one zero-balance DELETE branch in approve_transaction(uuid); aborting safely';
  END IF;

  v_definition := replace(v_definition, v_old, v_new);
  IF position('DELETE FROM public.stock' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'Unexpected remaining stock DELETE in approve_transaction(uuid); aborting safely';
  END IF;

  EXECUTE v_definition;
END
$migration$;
