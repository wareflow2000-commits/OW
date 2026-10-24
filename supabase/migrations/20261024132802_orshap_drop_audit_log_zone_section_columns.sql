-- Remove unused legacy zone/section dimensions from audit logs while preserving helper RPC signatures.
DO $migration$
DECLARE
  v_sig regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_sig:='public.app_insert_audit_log(uuid,text,text,text,jsonb,uuid,text,text,uuid,uuid,uuid,numeric,numeric,text)'::regprocedure;
  v_def:=replace(pg_get_functiondef(v_sig),E'\r\n',E'\n');
  v_old:=E'        warehouse_id,\n        zone_id,\n        section_id,\n        quantity_before';
  v_new:=E'        warehouse_id,\n        quantity_before';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Audit helper column list not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:=E'        p_warehouse_id,\n        p_zone_id,\n        p_section_id,\n        p_quantity_before';
  v_new:=E'        p_warehouse_id,\n        p_quantity_before';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Audit helper value list not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;

  v_sig:='public.approve_transaction(uuid)'::regprocedure;
  v_def:=replace(pg_get_functiondef(v_sig),E'\r\n',E'\n');
  v_old:='warehouse_id, zone_id, section_id, quantity_before, quantity_after,';
  v_new:='warehouse_id, quantity_before, quantity_after,';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Approval item audit column list not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='v_tx_rec.warehouse_id, v_tx_rec.zone_id, v_tx_rec.section_id,';
  v_new:='v_tx_rec.warehouse_id,';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Approval audit values not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='warehouse_id, zone_id, section_id, reference, details';
  v_new:='warehouse_id, reference, details';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Approval transaction audit column list not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;

  v_sig:='public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text)'::regprocedure;
  v_def:=pg_get_functiondef(v_sig);
  v_old:='warehouse_id,zone_id,reference,details'; v_new:='warehouse_id,reference,details';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Return audit columns not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='v_shelf.warehouse_id,NULL,btrim(p_reference_no)';
  v_new:='v_shelf.warehouse_id,btrim(p_reference_no)';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Return audit values not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;

  v_sig:='public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text)'::regprocedure;
  v_def:=pg_get_functiondef(v_sig);
  v_old:='warehouse_id,zone_id,reference,details'; v_new:='warehouse_id,reference,details';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transfer audit columns not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='v_src.warehouse_id,NULL,btrim(p_reference_no)';
  v_new:='v_src.warehouse_id,btrim(p_reference_no)';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transfer audit values not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;

  v_sig:='public.reject_stock_transfer_receipt(uuid,text)'::regprocedure;
  v_def:=pg_get_functiondef(v_sig);
  v_old:='warehouse_id,zone_id,reference,details'; v_new:='warehouse_id,reference,details';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Receipt rejection audit columns not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='v_shelf.warehouse_id,NULL,v_transfer.reference_no';
  v_new:='v_shelf.warehouse_id,v_transfer.reference_no';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Receipt rejection audit values not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;

  IF EXISTS(SELECT 1 FROM public.audit_logs WHERE zone_id IS NOT NULL OR section_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Cannot drop audit legacy fields while populated values remain';
  END IF;
END;
$migration$;
ALTER TABLE public.audit_logs DROP COLUMN IF EXISTS zone_id, DROP COLUMN IF EXISTS section_id;
