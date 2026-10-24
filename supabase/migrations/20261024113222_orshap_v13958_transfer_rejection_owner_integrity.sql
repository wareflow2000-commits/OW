-- ORSHAP WMS v13.9.58
-- Ensure transfer receipt rejection restores only the original stock owner's balance.
BEGIN;
CREATE OR REPLACE FUNCTION public.reject_stock_transfer_receipt(p_transfer_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
 v_user uuid:=auth.uid(); v_profile public.profiles%ROWTYPE; v_transfer public.stock_transfers%ROWTYPE;
 v_shelf public.shelves%ROWTYPE; v_before numeric:=0; v_after numeric; v_tx uuid; v_area uuid; v_lock_key text; v_owner uuid;
BEGIN
 IF v_user IS NULL OR NOT public.current_user_is_active() THEN RAISE EXCEPTION 'An active authenticated user is required'; END IF;
 IF NOT public.current_user_has_permission('action:stock_transfer:receive') THEN RAISE EXCEPTION 'Permission denied to reject a transfer receipt'; END IF;
 IF NULLIF(btrim(COALESCE(p_reason,'')),'') IS NULL THEN RAISE EXCEPTION 'A rejection reason is required'; END IF;
 SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';
 SELECT * INTO v_transfer FROM public.stock_transfers WHERE id=p_transfer_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Stock transfer not found'; END IF;
 IF v_transfer.status='REJECTED' THEN RETURN jsonb_build_object('success',true,'already_rejected',true,'transfer_id',p_transfer_id,'status','REJECTED'); END IF;
 IF v_transfer.status<>'IN_TRANSIT' THEN RAISE EXCEPTION 'Only an IN_TRANSIT transfer can be rejected'; END IF;
 v_owner:=v_transfer.administrative_department_id;
 IF v_owner IS NULL OR NOT EXISTS(SELECT 1 FROM public.administrative_departments WHERE id=v_owner AND is_active=true) THEN RAISE EXCEPTION 'Transfer owner is missing or inactive; cannot return stock to source'; END IF;
 IF COALESCE(v_profile.role,'') NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_transfer.destination_warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the destination warehouse'; END IF;
 SELECT * INTO v_shelf FROM public.shelves WHERE id=v_transfer.source_shelf_id AND warehouse_id=v_transfer.source_warehouse_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Source shelf is no longer valid for the source warehouse'; END IF;
 v_area:=v_shelf.storage_area_id;
 v_lock_key:=v_transfer.item_id::text||':'||v_transfer.source_shelf_id::text||':'||v_transfer.batch_no||':'||v_owner::text;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_lock_key,0));
 SELECT quantity INTO v_before FROM public.stock WHERE item_id=v_transfer.item_id AND shelf_id=v_transfer.source_shelf_id AND batch_no=v_transfer.batch_no AND storage_area_id=v_area AND administrative_department_id=v_owner FOR UPDATE;
 v_before:=COALESCE(v_before,0); v_after:=v_before+v_transfer.quantity; v_tx:=gen_random_uuid();
 INSERT INTO public.transactions(id,reference_no,transaction_type,status,warehouse_id,zone_id,section_id,storage_area_id,notes,created_by)
 VALUES(v_tx,v_transfer.reference_no||'-REJECT-RETURN','ADJUSTMENT_IN','APPROVED',v_shelf.warehouse_id,NULL,NULL,v_area,'Rejected transfer receipt; goods returned to source. Reason: '||btrim(p_reason),v_user);
 INSERT INTO public.transaction_lines(transaction_id,item_id,shelf_id,administrative_department_id,quantity,balance_before,balance_after,batch_no,expiry_date,storage_area_id,notes)
 VALUES(v_tx,v_transfer.item_id,v_transfer.source_shelf_id,v_owner,v_transfer.quantity,v_before,v_after,v_transfer.batch_no,v_transfer.expiry_date,v_area,'Transfer='||p_transfer_id::text||'; direction=REJECTED_RETURN; reason='||btrim(p_reason));
 INSERT INTO public.stock(item_id,shelf_id,administrative_department_id,quantity,batch_no,expiry_date,storage_area_id,updated_at)
 VALUES(v_transfer.item_id,v_transfer.source_shelf_id,v_owner,v_after,v_transfer.batch_no,v_transfer.expiry_date,v_area,now())
 ON CONFLICT (item_id, shelf_id, batch_no, administrative_department_id) DO UPDATE SET quantity=EXCLUDED.quantity,expiry_date=COALESCE(EXCLUDED.expiry_date,public.stock.expiry_date),storage_area_id=COALESCE(EXCLUDED.storage_area_id,public.stock.storage_area_id),updated_at=now();
 PERFORM public.log_transaction_ledger(p_transaction_id:=v_tx,p_ledger_type:='STOCK_TRANSFER',p_user_id:=v_user,p_warehouse_id:=v_shelf.warehouse_id,p_zone_id:=NULL::uuid,p_section_id:=NULL::uuid,p_shelf_id:=v_transfer.source_shelf_id,p_item_id:=v_transfer.item_id,p_quantity:=v_transfer.quantity,p_balance_before:=v_before,p_balance_after:=v_after,p_transaction_type:='ADJUSTMENT_IN',p_details:=jsonb_build_object('transfer_id',p_transfer_id,'rejected_at_destination',v_transfer.destination_warehouse_id,'reason',btrim(p_reason),'batch_no',v_transfer.batch_no,'administrative_department_id',v_owner,'storage_area_id',v_area),p_reference:=v_transfer.reference_no,p_approved:=true,p_reference_type:='STOCK_TRANSFER_REJECTED_RETURN',p_batch_no:=v_transfer.batch_no,p_expiry_date:=v_transfer.expiry_date);
 UPDATE public.stock_transfers SET status='REJECTED',rejected_by=v_user,rejected_at=now(),rejection_reason=btrim(p_reason),rejection_transaction_id=v_tx,notes=concat_ws(E'\n',NULLIF(notes,''),'REJECTED: '||btrim(p_reason)),updated_at=now() WHERE id=p_transfer_id;
 INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,zone_id,reference,details)
 VALUES(v_user,'STOCK_TRANSFER_RECEIPT_REJECTED','STOCK_TRANSFER',p_transfer_id::text,v_shelf.warehouse_id,NULL,v_transfer.reference_no,jsonb_build_object('reason',btrim(p_reason),'quantity_returned_to_source',v_transfer.quantity,'source_balance_after',v_after,'destination_warehouse_id',v_transfer.destination_warehouse_id,'administrative_department_id',v_owner));
 RETURN jsonb_build_object('success',true,'already_rejected',false,'transfer_id',p_transfer_id,'status','REJECTED','destination_transaction_id',v_tx,'source_balance_after',v_after);
END;$function$
;
COMMIT;