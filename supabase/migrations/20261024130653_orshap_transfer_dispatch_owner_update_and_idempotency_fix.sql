-- ORSHAP WMS v13.9.58
-- Fix owner-scoped transfer source updates and strict idempotency for dispatch retries.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef(v_sig);

  v_old := 'ELSE UPDATE public.stock SET quantity=v_src_after,updated_at=now() WHERE item_id=p_item_id AND shelf_id=p_source_shelf_id AND batch_no=v_batch; END IF;';
  v_new := 'ELSE UPDATE public.stock SET quantity=v_src_after,updated_at=now() WHERE item_id=p_item_id AND shelf_id=p_source_shelf_id AND batch_no=v_batch AND administrative_department_id IS NOT DISTINCT FROM v_owner; END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transfer source stock update not found; migration aborted'; END IF;
  v_def := replace(v_def,v_old,v_new);

  v_old := E'IF FOUND THEN\n  IF v_existing.reference_no IS DISTINCT FROM btrim(p_reference_no)';
  v_new := E'IF FOUND THEN\n  IF v_profile.role NOT IN (''SUPER_ADMIN'',''ADMIN'',''MANAGER'') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_existing.source_warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION ''User is not assigned to the source warehouse'' USING ERRCODE=''42501''; END IF;\n  IF v_existing.created_by IS DISTINCT FROM v_user OR v_existing.reference_no IS DISTINCT FROM btrim(p_reference_no)';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transfer idempotency identity guard not found; migration aborted'; END IF;
  v_def := replace(v_def,v_old,v_new);

  v_old := 'OR v_existing.administrative_department_id IS DISTINCT FROM v_owner THEN RAISE EXCEPTION ''Idempotency conflict: transfer ID was already used for different data''; END IF;';
  v_new := 'OR v_existing.administrative_department_id IS DISTINCT FROM v_owner OR v_existing.notes IS DISTINCT FROM p_notes OR v_existing.source_warehouse_id IS DISTINCT FROM (SELECT sh.warehouse_id FROM public.shelves sh WHERE sh.id=p_source_shelf_id) OR v_existing.destination_warehouse_id IS DISTINCT FROM (SELECT sh.warehouse_id FROM public.shelves sh WHERE sh.id=p_destination_shelf_id) OR v_existing.expiry_date IS DISTINCT FROM COALESCE(p_expiry_date,(SELECT s.expiry_date FROM public.stock s WHERE s.item_id=p_item_id AND s.shelf_id=p_source_shelf_id AND s.batch_no=v_batch AND s.administrative_department_id IS NOT DISTINCT FROM v_owner)) THEN RAISE EXCEPTION ''Idempotency conflict: transfer ID was already used for different data''; END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transfer idempotency payload guard not found; migration aborted'; END IF;
  v_def := replace(v_def,v_old,v_new);

  IF position('AND administrative_department_id IS NOT DISTINCT FROM v_owner; END IF;' IN v_def)=0
     OR position('v_existing.created_by IS DISTINCT FROM v_user' IN v_def)=0
     OR position('v_existing.expiry_date IS DISTINCT FROM COALESCE(p_expiry_date' IN v_def)=0
     OR position('v_existing.notes IS DISTINCT FROM p_notes' IN v_def)=0 THEN
    RAISE EXCEPTION 'Transfer dispatch guard verification failed; migration aborted';
  END IF;
  EXECUTE v_def;
END;
$migration$;
