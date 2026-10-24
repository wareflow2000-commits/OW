-- ORSHAP WMS v13.9.58 compatibility repair
-- Canonical physical location is warehouse + storage area + shelf.
-- Keep legacy columns for history, but stop reading legacy shelf zone/section at approval.
BEGIN;
CREATE OR REPLACE FUNCTION public.approve_transaction(p_transaction_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_actor_role text;
  v_actor_status text;
  v_actor_permissions text[];
  v_can_auto_approve boolean := false;
  v_require_approval boolean := true;
  v_tx_rec record;
  v_rec record;
  v_item record;
  v_old_qty numeric;
  v_new_qty numeric;
  v_is_inbound boolean;
  v_delta numeric;
  v_has_create_permission boolean := false;
  v_has_approve_permission boolean := false;
  v_has_auto_permission boolean := false;
  v_line_count integer := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication is required to approve transactions';
  END IF;

  SELECT p.role, p.status, COALESCE(p.custom_permissions, ARRAY[]::text[]),
         COALESCE(p.can_approve_without_workflow, false)
    INTO v_actor_role, v_actor_status, v_actor_permissions, v_can_auto_approve
  FROM public.profiles p
  WHERE p.id = v_user_id;

  IF NOT FOUND OR v_actor_status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'Active user profile required';
  END IF;

  SELECT COALESCE(s.value, 'TRUE') <> 'FALSE'
    INTO v_require_approval
  FROM public.system_settings s
  WHERE s.key = 'REQUIRE_APPROVAL';
  v_require_approval := COALESCE(v_require_approval, true);

  SELECT t.id, t.transaction_type, t.warehouse_id, NULL::uuid AS zone_id, NULL::uuid AS section_id,
         t.created_by, t.reference_no, t.status
    INTO v_tx_rec
  FROM public.transactions t
  WHERE t.id = p_transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction % not found', p_transaction_id;
  END IF;

  IF v_actor_role NOT IN ('SUPER_ADMIN', 'ADMIN', 'MANAGER')
     AND NOT EXISTS (
       SELECT 1
       FROM public.profiles p
       WHERE p.id = v_user_id
         AND cardinality(COALESCE(p.assigned_warehouse_ids, ARRAY[]::uuid[])) > 0
         AND v_tx_rec.warehouse_id = ANY(p.assigned_warehouse_ids)
     ) THEN
    RAISE EXCEPTION 'User is not assigned to the transaction warehouse';
  END IF;

  IF v_tx_rec.status = 'APPROVED' THEN
    RAISE EXCEPTION 'Transaction % has already been approved; duplicate posting blocked', p_transaction_id;
  END IF;
  IF v_tx_rec.status <> 'PENDING_APPROVAL' THEN
    RAISE EXCEPTION 'Transaction must be PENDING_APPROVAL before posting; current status: %', v_tx_rec.status;
  END IF;

  -- Apply the same guard at posting time, so an already-created request cannot bypass it.
  IF v_tx_rec.transaction_type = 'OPENING_BALANCE'
     AND v_actor_role NOT IN ('SUPER_ADMIN', 'MANAGER') THEN
    RAISE EXCEPTION 'Only a manager or super administrator may approve an opening balance';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.role_permissions rp
    WHERE rp.role_name = v_actor_role
      AND rp.permission_key = CASE v_tx_rec.transaction_type
        WHEN 'GRN' THEN 'action:transaction:grn:create'
        WHEN 'ISSUE' THEN 'action:transaction:issue:create'
                                                                                                      WHEN 'RETURN_TO_SUPPLIER' THEN 'action:transaction:issue:create'
                                                                                                              WHEN 'RETURN_FROM_CUSTOMER' THEN 'action:transaction:grn:create'
        WHEN 'ADJUSTMENT_IN' THEN 'action:transaction:adjustment:create'
        WHEN 'ADJUSTMENT_OUT' THEN 'action:transaction:adjustment:create'
        WHEN 'OPENING_BALANCE' THEN 'action:transaction:adjustment:create'
        WHEN 'RETURN_FROM_USAGE' THEN 'action:transaction:grn:create'
        ELSE NULL
      END
  ) OR v_actor_permissions @> ARRAY[
      CASE v_tx_rec.transaction_type
        WHEN 'GRN' THEN 'action:transaction:grn:create'
        WHEN 'ISSUE' THEN 'action:transaction:issue:create'
                                                                                                      WHEN 'RETURN_TO_SUPPLIER' THEN 'action:transaction:issue:create'
                                                                                                              WHEN 'RETURN_FROM_CUSTOMER' THEN 'action:transaction:grn:create'
        WHEN 'ADJUSTMENT_IN' THEN 'action:transaction:adjustment:create'
        WHEN 'ADJUSTMENT_OUT' THEN 'action:transaction:adjustment:create'
        WHEN 'OPENING_BALANCE' THEN 'action:transaction:adjustment:create'
        WHEN 'RETURN_FROM_USAGE' THEN 'action:transaction:grn:create'
        ELSE 'action:transaction:never'
      END
  ]::text[]
  INTO v_has_create_permission;

  SELECT EXISTS (
    SELECT 1 FROM public.role_permissions rp
    WHERE rp.role_name = v_actor_role
      AND rp.permission_key = 'action:transaction:approve'
  ) OR v_actor_permissions @> ARRAY['action:transaction:approve']::text[]
  INTO v_has_approve_permission;

  SELECT EXISTS (
    SELECT 1 FROM public.role_permissions rp
    WHERE rp.role_name = v_actor_role
      AND rp.permission_key = 'action:transaction:auto_approve'
  ) OR v_actor_permissions @> ARRAY['action:transaction:auto_approve']::text[]
  INTO v_has_auto_permission;

  IF v_actor_role IN ('SUPER_ADMIN', 'MANAGER', 'ADMIN') THEN
    NULL; -- privileged manager path
  ELSIF NOT v_require_approval
        AND v_tx_rec.created_by = v_user_id
        AND v_has_create_permission THEN
    NULL; -- global direct-execution mode, limited to the creator's permitted transaction type
  ELSIF v_tx_rec.created_by = v_user_id
        AND v_can_auto_approve
        AND v_has_auto_permission
        AND v_has_create_permission THEN
    NULL; -- per-user direct-execution permission
  ELSIF v_has_approve_permission THEN
    NULL; -- explicit approver permission
  ELSE
    RAISE EXCEPTION 'You do not have permission to post this transaction';
  END IF;

  SELECT count(*) INTO v_line_count
  FROM public.transaction_lines
  WHERE transaction_id = p_transaction_id;
  IF v_line_count = 0 THEN
    RAISE EXCEPTION 'Cannot approve a transaction without lines';
  END IF;

  v_is_inbound := v_tx_rec.transaction_type IN ('GRN', 'RETURN_FROM_USAGE', 'RETURN_FROM_CUSTOMER', 'ADJUSTMENT_IN', 'OPENING_BALANCE');
  IF v_tx_rec.transaction_type = 'ISSUE' THEN
    IF NOT EXISTS (SELECT 1 FROM public.administrative_departments ad WHERE ad.id = (SELECT t.recipient_department_id FROM public.transactions t WHERE t.id = p_transaction_id) AND ad.is_active = true) THEN RAISE EXCEPTION 'Issue recipient department is required and must be active'; END IF;
    IF NULLIF(btrim((SELECT t.receiver_name FROM public.transactions t WHERE t.id = p_transaction_id)), '') IS NULL THEN RAISE EXCEPTION 'Physical receiver name is required for issues'; END IF;
  END IF;
  IF v_tx_rec.transaction_type = 'GRN' AND NULLIF(btrim((SELECT t.supplier FROM public.transactions t WHERE t.id = p_transaction_id)), '') IS NULL THEN RAISE EXCEPTION 'Supplier is required for goods receipts'; END IF;
  IF v_tx_rec.transaction_type IN ('ADJUSTMENT_IN', 'ADJUSTMENT_OUT') AND NULLIF(btrim((SELECT t.adjustment_reason FROM public.transactions t WHERE t.id = p_transaction_id)), '') IS NULL THEN RAISE EXCEPTION 'Adjustment reason is required'; END IF;

  FOR v_rec IN
    SELECT tl.*
    FROM public.transaction_lines tl
    WHERE tl.transaction_id = p_transaction_id
    ORDER BY tl.id
    FOR UPDATE
  LOOP
    IF v_tx_rec.transaction_type IN ('GRN', 'ISSUE', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT') AND v_rec.administrative_department_id IS NULL THEN RAISE EXCEPTION 'Owning department is required for each stock transaction line'; END IF;
    IF v_rec.administrative_department_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.administrative_departments d
      WHERE d.id = v_rec.administrative_department_id AND d.is_active = true
    ) THEN
      RAISE EXCEPTION 'Administrative department is missing or inactive for line %', v_rec.id;
    END IF;
    IF v_rec.shelf_id IS NULL THEN
      RAISE EXCEPTION 'Shelf ID missing for line item %', v_rec.item_id;
    END IF;
    IF v_rec.quantity IS NULL OR v_rec.quantity <= 0 THEN
      RAISE EXCEPTION 'Transaction line quantity must be greater than zero for item %', v_rec.item_id;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.items i WHERE i.id = v_rec.item_id
    ) THEN
      RAISE EXCEPTION 'Transaction line item % does not exist', v_rec.item_id;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.shelves sh
      WHERE sh.id = v_rec.shelf_id
        AND sh.warehouse_id = v_tx_rec.warehouse_id
    ) THEN
      RAISE EXCEPTION 'Transaction line shelf % does not belong to transaction warehouse %', v_rec.shelf_id, v_tx_rec.warehouse_id;
    END IF;
    IF v_rec.storage_area_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.shelves sh
      WHERE sh.id = v_rec.shelf_id
        AND sh.warehouse_id = v_tx_rec.warehouse_id
        AND sh.storage_area_id = v_rec.storage_area_id
    ) THEN
      RAISE EXCEPTION 'Transaction line storage area does not match its shelf';
    END IF;

    v_old_qty := 0;
    SELECT s.quantity INTO v_old_qty
    FROM public.stock s
    WHERE s.item_id = v_rec.item_id
      AND s.shelf_id = v_rec.shelf_id
      AND s.batch_no = COALESCE(v_rec.batch_no, '')
      AND s.administrative_department_id IS NOT DISTINCT FROM v_rec.administrative_department_id
    FOR UPDATE;
    v_old_qty := COALESCE(v_old_qty, 0);

    IF v_is_inbound THEN
      INSERT INTO public.stock (item_id, shelf_id, storage_area_id, quantity, updated_at, created_at, batch_no, expiry_date, administrative_department_id)
      VALUES (v_rec.item_id, v_rec.shelf_id,
              COALESCE(v_rec.storage_area_id, (SELECT sh.storage_area_id FROM public.shelves sh WHERE sh.id=v_rec.shelf_id)),
              v_rec.quantity, NOW(), NOW(), COALESCE(v_rec.batch_no, ''), v_rec.expiry_date, v_rec.administrative_department_id)
      ON CONFLICT (item_id, shelf_id, batch_no, administrative_department_id)
      DO UPDATE SET quantity = public.stock.quantity + EXCLUDED.quantity,
                    storage_area_id = COALESCE(EXCLUDED.storage_area_id, public.stock.storage_area_id),
                    expiry_date = COALESCE(EXCLUDED.expiry_date, public.stock.expiry_date),
                    updated_at = NOW();

      SELECT s.quantity INTO v_new_qty
      FROM public.stock s
      WHERE s.item_id = v_rec.item_id
        AND s.shelf_id = v_rec.shelf_id
        AND s.batch_no = COALESCE(v_rec.batch_no, '')
        AND s.administrative_department_id IS NOT DISTINCT FROM v_rec.administrative_department_id;
      v_delta := v_rec.quantity;
    ELSE
      v_new_qty := v_old_qty - v_rec.quantity;
      IF v_new_qty < 0 THEN
        RAISE EXCEPTION 'Insufficient stock for item % at shelf % and batch %',
          v_rec.item_id, v_rec.shelf_id, COALESCE(v_rec.batch_no, '');
      END IF;
      IF v_new_qty = 0 THEN
        UPDATE public.stock
        SET quantity = 0,
            storage_area_id = COALESCE(v_rec.storage_area_id, (SELECT sh.storage_area_id FROM public.shelves sh WHERE sh.id=v_rec.shelf_id), storage_area_id),
            updated_at = NOW()
        WHERE item_id = v_rec.item_id
          AND shelf_id = v_rec.shelf_id
          AND batch_no = COALESCE(v_rec.batch_no, '')
          AND administrative_department_id IS NOT DISTINCT FROM v_rec.administrative_department_id;
      ELSE
        UPDATE public.stock
        SET quantity = v_new_qty,
            storage_area_id = COALESCE(v_rec.storage_area_id, (SELECT sh.storage_area_id FROM public.shelves sh WHERE sh.id=v_rec.shelf_id), storage_area_id),
            updated_at = NOW()
        WHERE item_id = v_rec.item_id
          AND shelf_id = v_rec.shelf_id
          AND batch_no = COALESCE(v_rec.batch_no, '')
          AND administrative_department_id IS NOT DISTINCT FROM v_rec.administrative_department_id;
      END IF;
      v_delta := -v_rec.quantity;
    END IF;

    UPDATE public.transaction_lines
    SET balance_before = v_old_qty, balance_after = v_new_qty
    WHERE id = v_rec.id;

    PERFORM public.log_transaction_ledger(
      p_transaction_id := p_transaction_id,
      p_ledger_type := 'TRANSACTION',
      p_user_id := v_tx_rec.created_by,
      p_warehouse_id := v_tx_rec.warehouse_id,
      p_zone_id := NULL::uuid,
      p_section_id := NULL::uuid,
      p_shelf_id := v_rec.shelf_id,
      p_item_id := v_rec.item_id,
      p_quantity := v_delta,
      p_balance_before := v_old_qty,
      p_balance_after := v_new_qty,
      p_transaction_type := v_tx_rec.transaction_type,
      p_details := jsonb_build_object('tx_line_id', v_rec.id, 'notes', v_rec.notes, 'administrative_department_id', v_rec.administrative_department_id, 'storage_area_id', COALESCE(v_rec.storage_area_id, (SELECT sh.storage_area_id FROM public.shelves sh WHERE sh.id = v_rec.shelf_id))),
      p_reference := v_tx_rec.reference_no,
      p_reference_type := 'APPROVAL',
      p_batch_no := COALESCE(v_rec.batch_no, ''),
      p_expiry_date := v_rec.expiry_date
    );

    SELECT i.code, i.name_en INTO v_item
    FROM public.items i WHERE i.id = v_rec.item_id;

    INSERT INTO public.audit_logs (
      user_id, action, entity, entity_id, item_id, item_code, item_name,
      warehouse_id, zone_id, section_id, quantity_before, quantity_after,
      reference, details
    ) VALUES (
      v_tx_rec.created_by, 'STOCK_UPDATE', 'ITEM', v_rec.item_id::text,
      v_rec.item_id, v_item.code, v_item.name_en,
      v_tx_rec.warehouse_id, v_tx_rec.zone_id, v_tx_rec.section_id,
      v_old_qty, v_new_qty, v_tx_rec.reference_no,
      jsonb_build_object('tx_id', p_transaction_id, 'type', v_tx_rec.transaction_type,
        'qty', v_rec.quantity, 'delta', v_delta, 'before', v_old_qty, 'after', v_new_qty,
        'shelf_id', v_rec.shelf_id, 'batch_no', v_rec.batch_no, 'administrative_department_id', v_rec.administrative_department_id)
    );
  END LOOP;

  UPDATE public.transactions
  SET status = 'APPROVED'
  WHERE id = p_transaction_id AND status = 'PENDING_APPROVAL';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction state changed before posting; no approval applied';
  END IF;

  INSERT INTO public.audit_logs (
    user_id, action, entity, entity_id, warehouse_id, zone_id, section_id, reference, details
  ) VALUES (
    v_user_id, 'APPROVE_TRANSACTION', 'TRANSACTION', p_transaction_id::text,
    v_tx_rec.warehouse_id, v_tx_rec.zone_id, v_tx_rec.section_id, v_tx_rec.reference_no,
    jsonb_build_object('message', 'Transaction approved and stock updated',
      'warehouse_id', v_tx_rec.warehouse_id, 'reference', v_tx_rec.reference_no,
      'approval_mode', CASE
        WHEN v_actor_role IN ('SUPER_ADMIN', 'MANAGER', 'ADMIN') THEN 'manager'
        WHEN NOT v_require_approval THEN 'global_direct'
        WHEN v_tx_rec.created_by = v_user_id THEN 'user_direct'
        ELSE 'approval'
      END)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_stock_return_request(p_return_id uuid, p_return_type text, p_reference_no text, p_item_id uuid, p_administrative_department_id uuid, p_quantity numeric, p_batch_no text DEFAULT ''::text, p_expiry_date date DEFAULT NULL::date, p_shelf_id uuid DEFAULT NULL::uuid, p_supplier text DEFAULT NULL::text, p_external_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
 v_user uuid:=auth.uid(); v_profile public.profiles%ROWTYPE; v_shelf public.shelves%ROWTYPE;
 v_type text:=upper(COALESCE(p_return_type,'')); v_permission text; v_existing public.transactions%ROWTYPE;
 v_area uuid; v_line uuid:=gen_random_uuid(); v_stock_expiry date; v_effective_expiry date:=p_expiry_date; v_owner uuid:=p_administrative_department_id;
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
  IF v_existing.transaction_type IS DISTINCT FROM v_type
      OR v_existing.reference_no IS DISTINCT FROM btrim(p_reference_no)
      OR v_existing.status NOT IN ('PENDING_APPROVAL','APPROVED')
      OR NOT EXISTS (SELECT 1 FROM public.transaction_lines tl
        WHERE tl.transaction_id=p_return_id AND tl.item_id=p_item_id AND tl.shelf_id=p_shelf_id
          AND tl.quantity=p_quantity AND tl.administrative_department_id IS NOT DISTINCT FROM p_administrative_department_id AND COALESCE(tl.batch_no,'')=COALESCE(p_batch_no,'')
          AND (p_expiry_date IS NULL OR tl.expiry_date IS NOT DISTINCT FROM p_expiry_date))
      OR COALESCE(v_existing.supplier,'') IS DISTINCT FROM COALESCE(NULLIF(btrim(COALESCE(p_supplier,'')),''),'')
      OR COALESCE(v_existing.external_reference,'') IS DISTINCT FROM COALESCE(NULLIF(btrim(COALESCE(p_external_reference,'')),''),'')
   THEN RAISE EXCEPTION 'Idempotency conflict: return ID already exists with different data'; END IF;
  RETURN jsonb_build_object('success',true,'already_created',true,'transaction_id',p_return_id,'status',v_existing.status);
 END IF;
 SELECT * INTO v_shelf FROM public.shelves WHERE id=p_shelf_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Return shelf not found'; END IF;
 IF v_shelf.storage_area_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.storage_areas a WHERE a.id=v_shelf.storage_area_id AND a.warehouse_id=v_shelf.warehouse_id) THEN
   RAISE EXCEPTION 'Return shelf must belong to a valid storage area';
 END IF;
 IF v_type='RETURN_TO_SUPPLIER' THEN
  IF v_owner IS NULL THEN RAISE EXCEPTION 'Owner department is required for supplier return'; END IF;
  PERFORM 1 FROM public.stock WHERE item_id=p_item_id AND shelf_id=p_shelf_id AND batch_no=COALESCE(p_batch_no,'') AND administrative_department_id IS NOT DISTINCT FROM v_owner AND quantity >= p_quantity FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient stock for selected owner, shelf and batch'; END IF;
  SELECT expiry_date INTO v_stock_expiry FROM public.stock WHERE item_id=p_item_id AND shelf_id=p_shelf_id AND batch_no=COALESCE(p_batch_no,'') AND administrative_department_id IS NOT DISTINCT FROM v_owner;
  IF p_expiry_date IS NOT NULL AND v_stock_expiry IS NOT NULL AND p_expiry_date IS DISTINCT FROM v_stock_expiry THEN RAISE EXCEPTION 'Expiry date does not match source batch'; END IF;
  v_effective_expiry:=COALESCE(v_stock_expiry,p_expiry_date);
 END IF;
 IF v_owner IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.administrative_departments d WHERE d.id=v_owner) THEN RAISE EXCEPTION 'Owner department not found'; END IF;
 IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_shelf.warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the return warehouse'; END IF;
 IF v_type='RETURN_TO_SUPPLIER' AND NULLIF(btrim(COALESCE(p_supplier,'')),'') IS NULL THEN RAISE EXCEPTION 'Supplier is required for return to supplier'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.items WHERE id=p_item_id) THEN RAISE EXCEPTION 'Item not found'; END IF;
 v_area:=v_shelf.storage_area_id;
 INSERT INTO public.transactions(id,reference_no,transaction_type,status,warehouse_id,zone_id,section_id,storage_area_id,external_reference,supplier,notes,created_by)
 VALUES(p_return_id,btrim(p_reference_no),v_type,'PENDING_APPROVAL',v_shelf.warehouse_id,NULL,NULL,v_area,NULLIF(btrim(COALESCE(p_external_reference,'')),''),NULLIF(btrim(COALESCE(p_supplier,'')),''),p_notes,v_user);
 INSERT INTO public.transaction_lines(id,transaction_id,item_id,shelf_id,quantity,batch_no,expiry_date,storage_area_id,administrative_department_id,notes)
 VALUES(v_line,p_return_id,p_item_id,p_shelf_id,p_quantity,NULLIF(COALESCE(p_batch_no,''),''),v_effective_expiry,v_area,v_owner,p_notes);
 INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,zone_id,reference,details)
 VALUES(v_user,'STOCK_RETURN_REQUEST_CREATED','TRANSACTION',p_return_id::text,v_shelf.warehouse_id,NULL,btrim(p_reference_no),jsonb_build_object('return_type',v_type,'item_id',p_item_id,'quantity',p_quantity,'batch_no',COALESCE(p_batch_no,''),'shelf_id',p_shelf_id,'storage_area_id',v_area,'administrative_department_id',v_owner,'supplier',p_supplier,'external_reference',p_external_reference));
 RETURN jsonb_build_object('success',true,'already_created',false,'transaction_id',p_return_id,'status','PENDING_APPROVAL');
END;
$function$;

-- Preserve the existing RPC signature for older clients, but do not let it
-- create supplier returns without an unambiguous stock owner.
CREATE OR REPLACE FUNCTION public.create_stock_return_request(
 p_return_id uuid,
 p_return_type text,
 p_reference_no text,
 p_item_id uuid,
 p_quantity numeric,
 p_batch_no text DEFAULT ''::text,
 p_expiry_date date DEFAULT NULL::date,
 p_shelf_id uuid DEFAULT NULL::uuid,
 p_supplier text DEFAULT NULL::text,
 p_external_reference text DEFAULT NULL::text,
 p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
 v_owner uuid;
 v_owner_count integer := 0;
 v_user uuid := auth.uid();
 v_profile public.profiles%ROWTYPE;
 v_shelf public.shelves%ROWTYPE;
BEGIN
 IF v_user IS NULL OR NOT public.current_user_is_active() THEN
   RAISE EXCEPTION 'An active authenticated user is required';
 END IF;
 IF NOT public.current_user_has_permission(
   CASE WHEN upper(COALESCE(p_return_type,'')) = 'RETURN_TO_SUPPLIER'
        THEN 'action:transaction:issue:create'
        ELSE 'action:transaction:grn:create' END
 ) THEN
   RAISE EXCEPTION 'Permission denied for return type %', p_return_type;
 END IF;

 IF upper(COALESCE(p_return_type,'')) = 'RETURN_TO_SUPPLIER' THEN
   SELECT * INTO v_shelf FROM public.shelves WHERE id = p_shelf_id;
   IF NOT FOUND THEN RAISE EXCEPTION 'Return shelf not found'; END IF;
   SELECT * INTO v_profile FROM public.profiles WHERE id = v_user AND status = 'ACTIVE';
   IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER')
      AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids, ARRAY[]::uuid[])) = 0
           OR NOT (v_shelf.warehouse_id = ANY(v_profile.assigned_warehouse_ids))) THEN
     RAISE EXCEPTION 'User is not assigned to the return warehouse';
   END IF;
   -- Idempotent retries use the owner recorded on the original request.
   SELECT tl.administrative_department_id
     INTO v_owner
     FROM public.transaction_lines tl
     JOIN public.transactions t ON t.id = tl.transaction_id
    WHERE t.id = p_return_id
      AND t.transaction_type = 'RETURN_TO_SUPPLIER'
      AND t.reference_no = btrim(COALESCE(p_reference_no,''))
      AND tl.item_id = p_item_id
      AND tl.shelf_id = p_shelf_id
      AND tl.quantity = p_quantity
      AND COALESCE(tl.batch_no,'') = COALESCE(p_batch_no,'')
      AND tl.administrative_department_id IS NOT NULL
    LIMIT 1;

   IF v_owner IS NULL THEN
     SELECT count(*), (array_agg(eligible.owner_id ORDER BY eligible.owner_id))[1]
       INTO v_owner_count, v_owner
       FROM (
         SELECT s.administrative_department_id AS owner_id
           FROM public.stock s
          WHERE s.item_id = p_item_id
            AND s.shelf_id = p_shelf_id
            AND s.batch_no = COALESCE(p_batch_no,'')
            AND s.administrative_department_id IS NOT NULL
          GROUP BY s.administrative_department_id
         HAVING sum(s.quantity) >= p_quantity
       ) AS eligible;

     IF v_owner_count <> 1 OR v_owner IS NULL THEN
       RAISE EXCEPTION 'Supplier return requires exactly one stock owner with sufficient quantity; select the owner explicitly in the current client';
     END IF;
   END IF;
 END IF;

 RETURN public.create_stock_return_request(
   p_return_id,
   p_return_type,
   p_reference_no,
   p_item_id,
   v_owner,
   p_quantity,
   p_batch_no,
   p_expiry_date,
   p_shelf_id,
   p_supplier,
   p_external_reference,
   p_notes
 );
END;
$function$;

REVOKE ALL ON FUNCTION public.approve_transaction(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_transaction(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.approve_transaction(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_transaction(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text) TO service_role;
COMMIT;
