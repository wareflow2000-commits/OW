-- ORSHAP WMS v13.9.58
-- Apply the zero-balance retention policy consistently to legacy transfer/movement
-- entry points that remain executable by authenticated clients.
-- Preserve each function's existing validation, audit, and ledger behavior.
DO $migration$
DECLARE
  v_sig text;
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
  v_signatures text[] := ARRAY[
    'public.dispatch_stock_transfer(uuid,text,uuid,numeric,text,date,uuid,uuid,text)',
    'public.dispatch_stock_transfer_with_destination_warehouse(uuid,text,uuid,numeric,text,date,uuid,uuid,text,uuid)',
    'public.process_stock_movement(text,text,uuid,numeric,text,date,uuid,uuid,text,text)'
  ];
BEGIN
  v_old := 'DELETE FROM public.stock WHERE item_id=p_item_id AND shelf_id=p_source_shelf_id AND batch_no=v_batch;';
  v_new := 'UPDATE public.stock SET quantity=0,updated_at=now() WHERE item_id=p_item_id AND shelf_id=p_source_shelf_id AND batch_no=v_batch;';

  FOREACH v_sig IN ARRAY v_signatures LOOP
    v_definition := pg_get_functiondef(v_sig::regprocedure);
    v_count := length(v_definition) - length(replace(v_definition, v_old, ''));
    IF v_count <> length(v_old) THEN
      RAISE EXCEPTION 'Expected exactly one source-stock DELETE in %, found count=%; aborting safely', v_sig, v_count / length(v_old);
    END IF;
    v_definition := replace(v_definition, v_old, v_new);
    IF position(v_old IN v_definition) > 0 THEN
      RAISE EXCEPTION 'Stock DELETE still present after patch for %; aborting safely', v_sig;
    END IF;
    EXECUTE v_definition;
  END LOOP;
END
$migration$;
