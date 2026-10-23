DO $migration$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef('public.create_transaction_with_lines(uuid,jsonb,jsonb)'::regprocedure);
  v_old := 'OR v_existing.warehouse_id IS DISTINCT FROM v_warehouse_id THEN';
  v_new := 'OR v_existing.warehouse_id IS DISTINCT FROM v_warehouse_id' ||
           ' OR v_existing.storage_area_id IS DISTINCT FROM NULLIF(p_transaction->>''storage_area_id'','''')::uuid' ||
           ' OR v_existing.external_reference IS DISTINCT FROM NULLIF(p_transaction->>''external_reference'','''')' ||
           ' OR v_existing.supplier IS DISTINCT FROM NULLIF(p_transaction->>''supplier'','''')' ||
           ' OR v_existing.receiver_name IS DISTINCT FROM NULLIF(p_transaction->>''receiver_name'','''')' ||
           ' OR v_existing.notes IS DISTINCT FROM NULLIF(p_transaction->>''notes'','''') THEN';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Transaction idempotency header anchor not found'; END IF;
  v_def := replace(v_def,v_old,v_new);
  v_old := 'OR l.shelf_id IS DISTINCT FROM x.shelf_id' ||
           E'\n         OR l.quantity IS DISTINCT FROM x.quantity';
  v_new := 'OR l.shelf_id IS DISTINCT FROM x.shelf_id' ||
           E'\n         OR l.storage_area_id IS DISTINCT FROM COALESCE(x.storage_area_id,(SELECT sh.storage_area_id FROM public.shelves sh WHERE sh.id=x.shelf_id))' ||
           E'\n         OR COALESCE(l.notes,'''') IS DISTINCT FROM COALESCE(x.notes,'''')' ||
           E'\n         OR l.quantity IS DISTINCT FROM x.quantity';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Transaction idempotency line anchor not found'; END IF;
  v_def := replace(v_def,v_old,v_new);
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.dispatch_stock_transfer_order_v2(uuid,text,uuid,uuid,jsonb,text)'::regprocedure);
  v_old := 'OR v_existing.destination_warehouse_id IS DISTINCT FROM p_destination_warehouse_id THEN';
  v_new := 'OR v_existing.destination_warehouse_id IS DISTINCT FROM p_destination_warehouse_id' ||
           ' OR v_existing.notes IS DISTINCT FROM p_notes THEN';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Transfer idempotency header anchor not found'; END IF;
  v_def := replace(v_def,v_old,v_new);
  EXECUTE v_def;
END
$migration$;
