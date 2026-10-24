-- ORSHAP WMS v13.9.58
-- Preserve the stock-owning department across transfer dispatch and posting.
-- No stock rows are backfilled or modified by this migration.
BEGIN;
CREATE OR REPLACE FUNCTION public.dispatch_stock_transfer(p_transfer_id uuid, p_reference_no text, p_item_id uuid, p_administrative_department_id uuid, p_quantity numeric, p_batch_no text DEFAULT ''::text, p_expiry_date date DEFAULT NULL::date, p_source_shelf_id uuid DEFAULT NULL::uuid, p_destination_shelf_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
 v_user uuid:=auth.uid(); v_profile public.profiles%ROWTYPE; v_src public.shelves%ROWTYPE; v_dst public.shelves%ROWTYPE; v_owner uuid:=p_administrative_department_id;
 v_batch text:=COALESCE(p_batch_no,''); v_src_qty numeric; v_dst_qty numeric:=0; v_src_after numeric; v_dst_after numeric; v_source_expiry date; v_dest_expiry date; v_effective_expiry date;
 v_src_tx uuid; v_dst_tx uuid; v_existing public.stock_transfers%ROWTYPE; v_status text;
 v_item_code text; v_item_name text; v_src_area uuid; v_dst_area uuid; v_lock_key text;
BEGIN
 IF v_user IS NULL OR NOT public.current_user_is_active() THEN RAISE EXCEPTION 'An active authenticated user is required'; END IF;
 IF NOT public.current_user_has_permission('action:stock_transfer:create') THEN RAISE EXCEPTION 'Permission denied to create stock transfers'; END IF;
 IF p_transfer_id IS NULL OR NULLIF(btrim(COALESCE(p_reference_no,'')),'') IS NULL THEN RAISE EXCEPTION 'Transfer ID and reference are required'; END IF;
 IF p_item_id IS NULL OR p_quantity IS NULL OR p_quantity<=0 OR p_quantity::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'A valid item and positive quantity are required'; END IF;
 IF p_source_shelf_id IS NULL OR p_destination_shelf_id IS NULL OR p_source_shelf_id=p_destination_shelf_id THEN RAISE EXCEPTION 'Different source and destination shelves are required'; END IF;
 SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Active user profile required'; END IF;
 SELECT * INTO v_existing FROM public.stock_transfers WHERE id=p_transfer_id;
 IF FOUND THEN
  IF v_existing.reference_no IS DISTINCT FROM btrim(p_reference_no) OR v_existing.item_id IS DISTINCT FROM p_item_id OR v_existing.quantity IS DISTINCT FROM p_quantity OR v_existing.source_shelf_id IS DISTINCT FROM p_source_shelf_id OR v_existing.destination_shelf_id IS DISTINCT FROM p_destination_shelf_id OR v_existing.batch_no IS DISTINCT FROM v_batch OR v_existing.administrative_department_id IS DISTINCT FROM v_owner THEN RAISE EXCEPTION 'Idempotency conflict: transfer ID was already used for different data'; END IF;
  RETURN jsonb_build_object('success',true,'already_processed',true,'transfer_id',v_existing.id,'status',v_existing.status,'source_transaction_id',v_existing.source_transaction_id,'destination_transaction_id',v_existing.destination_transaction_id);
 END IF;
 SELECT * INTO v_src FROM public.shelves WHERE id=p_source_shelf_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Source shelf not found'; END IF;
 SELECT * INTO v_dst FROM public.shelves WHERE id=p_destination_shelf_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Destination shelf not found'; END IF;
 IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_src.warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse'; END IF;
 IF v_owner IS NULL OR NOT EXISTS(SELECT 1 FROM public.administrative_departments WHERE id=v_owner AND is_active=true) THEN RAISE EXCEPTION 'Transfer requires an active stock-owning department'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.items WHERE id=p_item_id) THEN RAISE EXCEPTION 'Item not found'; END IF;
 SELECT code,name_en INTO v_item_code,v_item_name FROM public.items WHERE id=p_item_id;
 v_src_area:=v_src.storage_area_id;
 v_dst_area:=v_dst.storage_area_id;
 FOR v_lock_key IN SELECT k FROM (VALUES(p_item_id::text||':'||p_source_shelf_id::text||':'||v_batch||':'||v_owner::text),(p_item_id::text||':'||p_destination_shelf_id::text||':'||v_batch||':'||v_owner::text)) q(k) ORDER BY k LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended(v_lock_key,0));
 END LOOP;
 SELECT quantity,expiry_date INTO v_src_qty,v_source_expiry FROM public.stock WHERE item_id=p_item_id AND shelf_id=p_source_shelf_id AND batch_no=v_batch AND administrative_department_id IS NOT DISTINCT FROM v_owner FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'No source stock exists for this item and batch'; END IF;
 IF p_expiry_date IS NOT NULL AND v_source_expiry IS NOT NULL AND p_expiry_date IS DISTINCT FROM v_source_expiry THEN RAISE EXCEPTION 'Expiry date does not match source batch'; END IF;
 v_effective_expiry:=COALESCE(v_source_expiry,p_expiry_date);
 IF v_src_qty<p_quantity THEN RAISE EXCEPTION 'Insufficient stock for transfer; available %, requested %',v_src_qty,p_quantity; END IF;
 SELECT quantity,expiry_date INTO v_dst_qty,v_dest_expiry FROM public.stock WHERE item_id=p_item_id AND shelf_id=p_destination_shelf_id AND batch_no=v_batch AND administrative_department_id IS NOT DISTINCT FROM v_owner FOR UPDATE;
 v_dst_qty:=COALESCE(v_dst_qty,0);
 IF v_source_expiry IS NOT NULL AND v_dest_expiry IS NOT NULL AND v_source_expiry IS DISTINCT FROM v_dest_expiry THEN RAISE EXCEPTION 'Source and destination batch expiry dates differ'; END IF;
 IF p_expiry_date IS NOT NULL AND v_dest_expiry IS NOT NULL AND p_expiry_date IS DISTINCT FROM v_dest_expiry THEN RAISE EXCEPTION 'Expiry date does not match destination batch'; END IF;
 v_effective_expiry:=COALESCE(v_source_expiry,v_dest_expiry,p_expiry_date); v_src_after:=v_src_qty-p_quantity; v_dst_after:=v_dst_qty+p_quantity;
 v_src_tx:=gen_random_uuid();
 INSERT INTO public.transactions(id,reference_no,transaction_type,status,warehouse_id,zone_id,section_id,storage_area_id,notes,created_by)
 VALUES(v_src_tx,btrim(p_reference_no)||'-OUT','ADJUSTMENT_OUT','APPROVED',v_src.warehouse_id,NULL,NULL,v_src_area,COALESCE(p_notes,'Stock transfer dispatch'),v_user);
 INSERT INTO public.transaction_lines(transaction_id,item_id,shelf_id,administrative_department_id,quantity,balance_before,balance_after,batch_no,expiry_date,storage_area_id,notes)
 VALUES(v_src_tx,p_item_id,p_source_shelf_id,v_owner,p_quantity,v_src_qty,v_src_after,v_batch,v_effective_expiry,v_src_area,'Transfer='||p_transfer_id::text||'; direction=OUT');
 IF v_src_after=0 THEN UPDATE public.stock SET quantity=0,updated_at=now() WHERE item_id=p_item_id AND shelf_id=p_source_shelf_id AND batch_no=v_batch AND administrative_department_id IS NOT DISTINCT FROM v_owner;
 ELSE UPDATE public.stock SET quantity=v_src_after,updated_at=now() WHERE item_id=p_item_id AND shelf_id=p_source_shelf_id AND batch_no=v_batch; END IF;
 PERFORM public.log_transaction_ledger(p_transaction_id:=v_src_tx,p_ledger_type:='STOCK_TRANSFER',p_user_id:=v_user,p_warehouse_id:=v_src.warehouse_id,p_zone_id:=NULL::uuid,p_section_id:=NULL::uuid,p_shelf_id:=p_source_shelf_id,p_item_id:=p_item_id,p_quantity:=-p_quantity,p_balance_before:=v_src_qty,p_balance_after:=v_src_after,p_transaction_type:='ADJUSTMENT_OUT',p_details:=jsonb_build_object('transfer_id',p_transfer_id,'destination_warehouse_id',v_dst.warehouse_id,'destination_shelf_id',p_destination_shelf_id,'batch_no',v_batch,'administrative_department_id',v_owner,'storage_area_id',v_src_area),p_reference:=btrim(p_reference_no),p_approved:=true,p_reference_type:='STOCK_TRANSFER',p_batch_no:=v_batch,p_expiry_date:=v_effective_expiry);
 IF v_src.warehouse_id=v_dst.warehouse_id THEN
  v_dst_tx:=gen_random_uuid();
  INSERT INTO public.transactions(id,reference_no,transaction_type,status,warehouse_id,zone_id,section_id,storage_area_id,notes,created_by)
  VALUES(v_dst_tx,btrim(p_reference_no)||'-IN','ADJUSTMENT_IN','APPROVED',v_dst.warehouse_id,NULL,NULL,v_dst_area,COALESCE(p_notes,'Same-warehouse shelf transfer'),v_user);
  INSERT INTO public.transaction_lines(transaction_id,item_id,shelf_id,administrative_department_id,quantity,balance_before,balance_after,batch_no,expiry_date,storage_area_id,notes)
  VALUES(v_dst_tx,p_item_id,p_destination_shelf_id,v_owner,p_quantity,v_dst_qty,v_dst_after,v_batch,v_effective_expiry,v_dst_area,'Transfer='||p_transfer_id::text||'; direction=IN');
  INSERT INTO public.stock(item_id,shelf_id,administrative_department_id,quantity,batch_no,expiry_date,storage_area_id,updated_at) VALUES(p_item_id,p_destination_shelf_id,v_owner,v_dst_after,v_batch,v_effective_expiry,v_dst_area,now())
  ON CONFLICT(item_id,shelf_id,batch_no,administrative_department_id) DO UPDATE SET quantity=EXCLUDED.quantity,expiry_date=COALESCE(EXCLUDED.expiry_date,public.stock.expiry_date),storage_area_id=COALESCE(EXCLUDED.storage_area_id,public.stock.storage_area_id),updated_at=now();
  PERFORM public.log_transaction_ledger(p_transaction_id:=v_dst_tx,p_ledger_type:='STOCK_TRANSFER',p_user_id:=v_user,p_warehouse_id:=v_dst.warehouse_id,p_zone_id:=NULL::uuid,p_section_id:=NULL::uuid,p_shelf_id:=p_destination_shelf_id,p_item_id:=p_item_id,p_quantity:=p_quantity,p_balance_before:=v_dst_qty,p_balance_after:=v_dst_after,p_transaction_type:='ADJUSTMENT_IN',p_details:=jsonb_build_object('transfer_id',p_transfer_id,'source_warehouse_id',v_src.warehouse_id,'source_shelf_id',p_source_shelf_id,'batch_no',v_batch,'administrative_department_id',v_owner,'storage_area_id',v_dst_area),p_reference:=btrim(p_reference_no),p_approved:=true,p_reference_type:='STOCK_TRANSFER',p_batch_no:=v_batch,p_expiry_date:=v_effective_expiry);
  v_status:='COMPLETED';
 ELSE v_status:='IN_TRANSIT'; END IF;
 INSERT INTO public.stock_transfers(id,reference_no,item_id,administrative_department_id,quantity,batch_no,expiry_date,source_warehouse_id,source_shelf_id,destination_warehouse_id,destination_shelf_id,status,notes,created_by,dispatched_by,source_transaction_id,destination_transaction_id,received_by,received_at)
 VALUES(p_transfer_id,btrim(p_reference_no),p_item_id,v_owner,p_quantity,v_batch,v_effective_expiry,v_src.warehouse_id,p_source_shelf_id,v_dst.warehouse_id,p_destination_shelf_id,v_status,p_notes,v_user,v_user,v_src_tx,v_dst_tx,CASE WHEN v_status='COMPLETED' THEN v_user END,CASE WHEN v_status='COMPLETED' THEN now() END);
 INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,zone_id,reference,details)
 VALUES(v_user,'STOCK_TRANSFER_DISPATCH','STOCK_TRANSFER',p_transfer_id::text,v_src.warehouse_id,NULL,btrim(p_reference_no),jsonb_build_object('status',v_status,'item_id',p_item_id,'quantity',p_quantity,'batch_no',v_batch,'source_shelf_id',p_source_shelf_id,'destination_shelf_id',p_destination_shelf_id,'destination_warehouse_id',v_dst.warehouse_id,'administrative_department_id',v_owner));
 RETURN jsonb_build_object('success',true,'already_processed',false,'transfer_id',p_transfer_id,'status',v_status,'source_transaction_id',v_src_tx,'destination_transaction_id',v_dst_tx,'source_balance_after',v_src_after,'destination_balance_after',CASE WHEN v_status='COMPLETED' THEN v_dst_after ELSE NULL END);
END;$function$
;
CREATE OR REPLACE FUNCTION public.dispatch_stock_transfer(
 p_transfer_id uuid,
 p_reference_no text,
 p_item_id uuid,
 p_quantity numeric,
 p_batch_no text DEFAULT ''::text,
 p_expiry_date date DEFAULT NULL::date,
 p_source_shelf_id uuid DEFAULT NULL::uuid,
 p_destination_shelf_id uuid DEFAULT NULL::uuid,
 p_notes text DEFAULT NULL::text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
 v_user uuid := auth.uid();
 v_profile public.profiles%ROWTYPE;
 v_src public.shelves%ROWTYPE;
 v_owner uuid;
 v_owner_count integer := 0;
 v_existing_found boolean := false;
 v_batch text := COALESCE(p_batch_no,'');
BEGIN
 IF v_user IS NULL OR NOT public.current_user_is_active() THEN RAISE EXCEPTION 'An active authenticated user is required'; END IF;
 IF NOT public.current_user_has_permission('action:stock_transfer:create') THEN RAISE EXCEPTION 'Permission denied to create stock transfers'; END IF;
 SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Active user profile required'; END IF;
 SELECT administrative_department_id INTO v_owner FROM public.stock_transfers WHERE id=p_transfer_id;
 v_existing_found := FOUND;
 IF v_existing_found THEN
   RETURN public.dispatch_stock_transfer(p_transfer_id,p_reference_no,p_item_id,v_owner,p_quantity,p_batch_no,p_expiry_date,p_source_shelf_id,p_destination_shelf_id,p_notes);
 END IF;
 SELECT * INTO v_src FROM public.shelves WHERE id=p_source_shelf_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Source shelf not found'; END IF;
 IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER')
    AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT (v_src.warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN
   RAISE EXCEPTION 'User is not assigned to the source warehouse';
 END IF;
 SELECT count(*), (array_agg(owner_id ORDER BY owner_id NULLS FIRST))[1]
   INTO v_owner_count, v_owner
   FROM (
     SELECT administrative_department_id AS owner_id
       FROM public.stock
      WHERE item_id=p_item_id AND shelf_id=p_source_shelf_id AND batch_no=v_batch AND quantity >= p_quantity
      GROUP BY administrative_department_id
     HAVING sum(quantity) >= p_quantity
   ) eligible;
 IF v_owner_count <> 1 OR v_owner IS NULL THEN
   RAISE EXCEPTION 'Transfer requires exactly one active stock owner; select the owner in the current client';
 END IF;
 RETURN public.dispatch_stock_transfer(p_transfer_id,p_reference_no,p_item_id,v_owner,p_quantity,p_batch_no,p_expiry_date,p_source_shelf_id,p_destination_shelf_id,p_notes);
END;
$function$;
REVOKE ALL ON FUNCTION public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text) TO service_role;
COMMIT;