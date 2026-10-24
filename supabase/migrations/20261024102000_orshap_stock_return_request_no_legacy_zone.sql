-- Return-request creation uses storage_area_id directly and leaves legacy transaction snapshot IDs NULL.
-- Stock and ledger rows are not changed by this function definition migration.
CREATE OR REPLACE FUNCTION public.create_stock_return_request(
 p_return_id uuid, p_return_type text, p_reference_no text, p_item_id uuid, p_quantity numeric,
 p_batch_no text DEFAULT ''::text, p_expiry_date date DEFAULT NULL::date, p_shelf_id uuid DEFAULT NULL::uuid,
 p_supplier text DEFAULT NULL::text, p_external_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
 v_user uuid:=auth.uid(); v_profile public.profiles%ROWTYPE; v_shelf public.shelves%ROWTYPE;
 v_type text:=upper(COALESCE(p_return_type,'')); v_permission text; v_existing public.transactions%ROWTYPE;
 v_area uuid; v_line uuid:=gen_random_uuid(); v_stock_expiry date; v_effective_expiry date:=p_expiry_date;
BEGIN
 IF v_user IS NULL OR NOT public.current_user_is_active() THEN RAISE EXCEPTION 'An active authenticated user is required'; END IF;
 IF p_return_id IS NULL OR NULLIF(btrim(COALESCE(p_reference_no,'')),'') IS NULL THEN RAISE EXCEPTION 'Return ID and reference are required'; END IF;
 IF p_item_id IS NULL OR p_quantity IS NULL OR p_quantity<=0 OR p_quantity::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'A valid item and positive quantity are required'; END IF;
 IF v_type NOT IN ('RETURN_FROM_USAGE','RETURN_FROM_CUSTOMER','RETURN_TO_SUPPLIER') THEN RAISE EXCEPTION 'Unsupported return type'; END IF;
 v_permission:=CASE WHEN v_type='RETURN_TO_SUPPLIER' THEN 'action:transaction:issue:create' ELSE 'action:transaction:grn:create' END;
 IF NOT public.current_user_has_permission(v_permission) THEN RAISE EXCEPTION 'Permission denied for return type %',v_type; END IF;
 SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';
 SELECT * INTO v_existing FROM public.transactions WHERE id=p_return_id;
 IF FOUND THEN
  IF v_existing.transaction_type IS DISTINCT FROM v_type OR v_existing.reference_no IS DISTINCT FROM btrim(p_reference_no)
      OR v_existing.status NOT IN ('PENDING_APPROVAL','APPROVED')
      OR NOT EXISTS (SELECT 1 FROM public.transaction_lines tl WHERE tl.transaction_id=p_return_id AND tl.item_id=p_item_id AND tl.shelf_id=p_shelf_id AND tl.quantity=p_quantity AND COALESCE(tl.batch_no,'')=COALESCE(p_batch_no,'') AND (p_expiry_date IS NULL OR tl.expiry_date IS NOT DISTINCT FROM p_expiry_date))
      OR COALESCE(v_existing.supplier,'') IS DISTINCT FROM COALESCE(NULLIF(btrim(COALESCE(p_supplier,'')),''),'')
      OR COALESCE(v_existing.external_reference,'') IS DISTINCT FROM COALESCE(NULLIF(btrim(COALESCE(p_external_reference,'')),''),'')
   THEN RAISE EXCEPTION 'Idempotency conflict: return ID already exists with different data'; END IF;
  RETURN jsonb_build_object('success',true,'already_created',true,'transaction_id',p_return_id,'status',v_existing.status);
 END IF;
 SELECT * INTO v_shelf FROM public.shelves WHERE id=p_shelf_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Return shelf not found'; END IF;
 IF v_shelf.storage_area_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.storage_areas a WHERE a.id=v_shelf.storage_area_id AND a.warehouse_id=v_shelf.warehouse_id) THEN RAISE EXCEPTION 'Return shelf must belong to a valid storage area'; END IF;
 IF v_type='RETURN_TO_SUPPLIER' THEN
  SELECT expiry_date INTO v_stock_expiry FROM public.stock WHERE item_id=p_item_id AND shelf_id=p_shelf_id AND batch_no=COALESCE(p_batch_no,'');
  IF p_expiry_date IS NOT NULL AND v_stock_expiry IS NOT NULL AND p_expiry_date IS DISTINCT FROM v_stock_expiry THEN RAISE EXCEPTION 'Expiry date does not match source batch'; END IF;
  v_effective_expiry:=COALESCE(v_stock_expiry,p_expiry_date);
 END IF;
 IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_shelf.warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the return warehouse'; END IF;
 IF v_type='RETURN_TO_SUPPLIER' AND NULLIF(btrim(COALESCE(p_supplier,'')),'') IS NULL THEN RAISE EXCEPTION 'Supplier is required for return to supplier'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.items WHERE id=p_item_id) THEN RAISE EXCEPTION 'Item not found'; END IF;
 v_area:=v_shelf.storage_area_id;
 INSERT INTO public.transactions(id,reference_no,transaction_type,status,warehouse_id,zone_id,section_id,storage_area_id,external_reference,supplier,notes,created_by)
 VALUES(p_return_id,btrim(p_reference_no),v_type,'PENDING_APPROVAL',v_shelf.warehouse_id,NULL,NULL,v_area,NULLIF(btrim(COALESCE(p_external_reference,'')),''),NULLIF(btrim(COALESCE(p_supplier,'')),''),p_notes,v_user);
 INSERT INTO public.transaction_lines(id,transaction_id,item_id,shelf_id,quantity,batch_no,expiry_date,storage_area_id,notes)
 VALUES(v_line,p_return_id,p_item_id,p_shelf_id,p_quantity,NULLIF(COALESCE(p_batch_no,''),''),v_effective_expiry,v_area,p_notes);
 INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,zone_id,reference,details)
 VALUES(v_user,'STOCK_RETURN_REQUEST_CREATED','TRANSACTION',p_return_id::text,v_shelf.warehouse_id,NULL,btrim(p_reference_no),jsonb_build_object('return_type',v_type,'item_id',p_item_id,'quantity',p_quantity,'batch_no',COALESCE(p_batch_no,''),'shelf_id',p_shelf_id,'storage_area_id',v_area,'supplier',p_supplier,'external_reference',p_external_reference));
 RETURN jsonb_build_object('success',true,'already_created',false,'transaction_id',p_return_id,'status','PENDING_APPROVAL');
END;
$function$;
