-- ORSHAP WMS v13.9.58: privileged roles do not override explicit warehouse assignments in transaction and stocktake RPCs.
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

  IF NOT public.current_user_can_access_warehouse(v_tx_rec.warehouse_id) THEN
    RAISE EXCEPTION 'User is not assigned to the transaction warehouse' USING ERRCODE='42501';
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
    ORDER BY tl.item_id, tl.shelf_id, COALESCE(tl.batch_no, ''), tl.administrative_department_id NULLS FIRST, tl.id
    FOR UPDATE
  LOOP
    IF v_tx_rec.transaction_type IN ('GRN', 'ISSUE', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT', 'RETURN_FROM_USAGE', 'RETURN_FROM_CUSTOMER', 'RETURN_TO_SUPPLIER') AND v_rec.administrative_department_id IS NULL THEN RAISE EXCEPTION 'Owning department is required for each stock transaction line'; END IF;
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
      warehouse_id, quantity_before, quantity_after,
      reference, details
    ) VALUES (
      v_tx_rec.created_by, 'STOCK_UPDATE', 'ITEM', v_rec.item_id::text,
      v_rec.item_id, v_item.code, v_item.name_en,
      v_tx_rec.warehouse_id,
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
    user_id, action, entity, entity_id, warehouse_id, reference, details
  ) VALUES (
    v_user_id, 'APPROVE_TRANSACTION', 'TRANSACTION', p_transaction_id::text,
    v_tx_rec.warehouse_id, v_tx_rec.reference_no,
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
$function$

;
CREATE OR REPLACE FUNCTION public.reject_transaction(p_transaction_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_profile public.profiles%ROWTYPE;
  v_tx public.transactions%ROWTYPE;
BEGIN
  IF v_user IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'Active authenticated user required';
  END IF;
  IF NULLIF(btrim(COALESCE(p_reason,'')),'') IS NULL THEN
    RAISE EXCEPTION 'A rejection reason is required';
  END IF;
  SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';
  IF NOT FOUND THEN RAISE EXCEPTION 'Active user profile required'; END IF;
  IF NOT public.current_user_has_permission('action:transaction:reject')
     AND v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') THEN
    RAISE EXCEPTION 'Permission denied to reject transactions';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id=p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF NOT public.current_user_can_access_warehouse(v_tx.warehouse_id) THEN
    RAISE EXCEPTION 'User is not assigned to the transaction warehouse' USING ERRCODE='42501';
  END IF;
  IF v_tx.status <> 'PENDING_APPROVAL' THEN
    RAISE EXCEPTION 'Only a pending transaction can be rejected; current status: %',v_tx.status;
  END IF;
  UPDATE public.transactions
     SET status='REJECTED', rejection_reason=btrim(p_reason)
   WHERE id=p_transaction_id AND status='PENDING_APPROVAL';
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction state changed before rejection'; END IF;
  INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,reference,details)
  VALUES(v_user,'REJECT_TRANSACTION','TRANSACTION',p_transaction_id::text,v_tx.warehouse_id,
         v_tx.reference_no,jsonb_build_object('reason',btrim(p_reason),'previous_status',v_tx.status,'new_status','REJECTED')::text);
  RETURN jsonb_build_object('success',true,'transaction_id',p_transaction_id,'status','REJECTED');
END;
$function$

;
CREATE OR REPLACE FUNCTION public.create_transaction_with_lines(p_transaction_id uuid, p_transaction jsonb, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_role text;
  v_status text;
  v_assigned uuid[];
  v_type text;
  v_permission text;
  v_warehouse_id uuid;
  v_existing public.transactions%ROWTYPE;
  v_existing_count integer;
  v_input_count integer;
  v_line record;
BEGIN
  IF v_user_id IS NULL OR NOT (SELECT public.current_user_is_active()) THEN
    RAISE EXCEPTION 'An active authenticated user is required';
  END IF;
  IF p_transaction_id IS NULL THEN RAISE EXCEPTION 'p_transaction_id is required'; END IF;
  IF p_transaction IS NULL OR jsonb_typeof(p_transaction) <> 'object' THEN
    RAISE EXCEPTION 'p_transaction must be a JSON object';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 1 THEN
    RAISE EXCEPTION 'At least one transaction line is required';
  END IF;

  SELECT p.role, p.status, COALESCE(p.assigned_warehouse_ids, ARRAY[]::uuid[])
    INTO v_role, v_status, v_assigned
  FROM public.profiles p WHERE p.id = v_user_id;
  IF NOT FOUND OR v_status <> 'ACTIVE' THEN RAISE EXCEPTION 'Active user profile required'; END IF;

  v_type := upper(COALESCE(p_transaction->>'transaction_type',''));
  v_permission := CASE v_type
    WHEN 'GRN' THEN 'action:transaction:grn:create'
    WHEN 'RETURN_FROM_USAGE' THEN 'action:transaction:grn:create'
                                                          WHEN 'RETURN_FROM_CUSTOMER' THEN 'action:transaction:grn:create'
                                                              WHEN 'RETURN_TO_SUPPLIER' THEN 'action:transaction:issue:create'
    WHEN 'ISSUE' THEN 'action:transaction:issue:create'
    WHEN 'ADJUSTMENT_IN' THEN 'action:transaction:adjustment:create'
    WHEN 'ADJUSTMENT_OUT' THEN 'action:transaction:adjustment:create'
    WHEN 'OPENING_BALANCE' THEN 'action:transaction:adjustment:create'
    ELSE NULL
  END;
  IF v_permission IS NULL THEN RAISE EXCEPTION 'Unsupported transaction type: %', v_type; END IF;
  IF NOT (SELECT public.current_user_has_permission(v_permission)) THEN
    RAISE EXCEPTION 'Permission denied to create transaction type %', v_type;
  END IF;

  -- Opening balances are privileged initial accounting entries, not ordinary adjustments.
  IF v_type = 'OPENING_BALANCE' AND v_role NOT IN ('SUPER_ADMIN', 'MANAGER') THEN
    RAISE EXCEPTION 'Only a manager or super administrator may create an opening balance';
  END IF;

  v_warehouse_id := NULLIF(p_transaction->>'warehouse_id','')::uuid;
  IF v_warehouse_id IS NULL THEN RAISE EXCEPTION 'warehouse_id is required'; END IF;
  IF NOT public.current_user_can_access_warehouse(v_warehouse_id) THEN
    RAISE EXCEPTION 'User is not assigned to the requested warehouse' USING ERRCODE='42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id = v_warehouse_id) THEN
    RAISE EXCEPTION 'Warehouse not found';
  END IF;
  IF NULLIF(p_transaction->>'storage_area_id','') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.storage_areas a
    WHERE a.id = NULLIF(p_transaction->>'storage_area_id','')::uuid AND a.warehouse_id=v_warehouse_id
  ) THEN
    RAISE EXCEPTION 'Transaction storage area must belong to the selected warehouse';
  END IF;
  IF NULLIF(btrim(COALESCE(p_transaction->>'reference_no','')),'') IS NULL THEN
    RAISE EXCEPTION 'Transaction reference is required';
  END IF;

  -- Enforce required transaction metadata before an idempotent retry or insert.
  IF v_type = 'GRN' AND NULLIF(btrim(COALESCE(p_transaction->>'supplier','')), '') IS NULL THEN
    RAISE EXCEPTION 'Supplier is required for goods receipts';
  END IF;
  IF v_type = 'ISSUE' THEN
    IF NULLIF(p_transaction->>'recipient_department_id','') IS NULL THEN
      RAISE EXCEPTION 'Recipient department is required for issues';
    END IF;
    IF NULLIF(btrim(COALESCE(p_transaction->>'receiver_name','')), '') IS NULL THEN
      RAISE EXCEPTION 'Physical receiver name is required for issues';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.administrative_departments d
                   WHERE d.id = NULLIF(p_transaction->>'recipient_department_id','')::uuid AND d.is_active = true) THEN
      RAISE EXCEPTION 'Recipient department is missing or inactive';
    END IF;
  END IF;
  IF v_type IN ('ADJUSTMENT_IN','ADJUSTMENT_OUT')
     AND NULLIF(btrim(COALESCE(p_transaction->>'adjustment_reason','')), '') IS NULL THEN
    RAISE EXCEPTION 'Adjustment reason is required';
  END IF;

  SELECT * INTO v_existing FROM public.transactions t WHERE t.id = p_transaction_id;
  IF FOUND THEN
    IF v_existing.created_by IS DISTINCT FROM v_user_id
       OR v_existing.reference_no IS DISTINCT FROM btrim(p_transaction->>'reference_no')
       OR v_existing.transaction_type IS DISTINCT FROM v_type
       OR v_existing.warehouse_id IS DISTINCT FROM v_warehouse_id OR v_existing.storage_area_id IS DISTINCT FROM NULLIF(p_transaction->>'storage_area_id','')::uuid OR v_existing.external_reference IS DISTINCT FROM NULLIF(p_transaction->>'external_reference','') OR v_existing.supplier IS DISTINCT FROM NULLIF(p_transaction->>'supplier','') OR v_existing.receiver_name IS DISTINCT FROM NULLIF(p_transaction->>'receiver_name','') OR v_existing.notes IS DISTINCT FROM NULLIF(p_transaction->>'notes','') OR v_existing.recipient_department_id IS DISTINCT FROM NULLIF(p_transaction->>'recipient_department_id','')::uuid OR v_existing.adjustment_reason IS DISTINCT FROM NULLIF(p_transaction->>'adjustment_reason','') THEN
      RAISE EXCEPTION 'Idempotency conflict: transaction id already belongs to a different request';
    END IF;
    SELECT count(*) INTO v_existing_count FROM public.transaction_lines l WHERE l.transaction_id=p_transaction_id;
    SELECT count(*) INTO v_input_count FROM jsonb_to_recordset(p_lines) AS x(id uuid);
    IF v_existing_count <> v_input_count OR EXISTS (
      SELECT 1
      FROM jsonb_to_recordset(p_lines) AS x(id uuid,item_id uuid,shelf_id uuid,storage_area_id uuid,administrative_department_id uuid,quantity numeric,batch_no text,expiry_date date,notes text)
      LEFT JOIN public.transaction_lines l ON l.id=x.id AND l.transaction_id=p_transaction_id
      WHERE l.id IS NULL OR l.item_id IS DISTINCT FROM x.item_id
         OR l.shelf_id IS DISTINCT FROM x.shelf_id
         OR l.storage_area_id IS DISTINCT FROM COALESCE(x.storage_area_id,(SELECT sh.storage_area_id FROM public.shelves sh WHERE sh.id=x.shelf_id))
         OR COALESCE(l.notes,'') IS DISTINCT FROM COALESCE(x.notes,'')
         OR l.quantity IS DISTINCT FROM x.quantity
         OR COALESCE(l.batch_no,'') IS DISTINCT FROM COALESCE(x.batch_no,'')
         OR l.expiry_date IS DISTINCT FROM x.expiry_date
         OR l.administrative_department_id IS DISTINCT FROM x.administrative_department_id
    ) THEN
      RAISE EXCEPTION 'Idempotency conflict: transaction lines do not match the original request';
    END IF;
    RETURN jsonb_build_object('transaction_id',p_transaction_id,'status',v_existing.status,'already_created',true);
  END IF;

  FOR v_line IN
    SELECT x.* FROM jsonb_to_recordset(p_lines) AS x(
      id uuid,item_id uuid,shelf_id uuid,storage_area_id uuid,administrative_department_id uuid,quantity numeric,batch_no text,expiry_date date,notes text
    )
  LOOP
    IF v_line.id IS NULL OR v_line.item_id IS NULL OR v_line.shelf_id IS NULL THEN
      RAISE EXCEPTION 'Each line requires stable id, item_id, and shelf_id';
    END IF;
    IF v_line.quantity IS NULL OR v_line.quantity <= 0 THEN
      RAISE EXCEPTION 'Each transaction line quantity must be greater than zero';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.items i WHERE i.id=v_line.item_id) THEN
      RAISE EXCEPTION 'Transaction line item not found';
    END IF;
    IF v_type IN ('GRN','ISSUE','ADJUSTMENT_IN','ADJUSTMENT_OUT','RETURN_FROM_USAGE','RETURN_FROM_CUSTOMER','RETURN_TO_SUPPLIER')
       AND v_line.administrative_department_id IS NULL THEN
      RAISE EXCEPTION 'Owning department is required for each stock transaction line';
    END IF;
    IF v_line.administrative_department_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.administrative_departments d
      WHERE d.id = v_line.administrative_department_id AND d.is_active = true
    ) THEN
      RAISE EXCEPTION 'Administrative department not found or inactive';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.shelves s WHERE s.id=v_line.shelf_id AND s.warehouse_id=v_warehouse_id) THEN
      RAISE EXCEPTION 'Each shelf must belong to the selected warehouse';
    END IF;
    IF v_line.storage_area_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.shelves s
      WHERE s.id=v_line.shelf_id AND s.warehouse_id=v_warehouse_id
        AND s.storage_area_id=v_line.storage_area_id
    ) THEN
      RAISE EXCEPTION 'Storage area must match the selected shelf';
    END IF;
  END LOOP;

  INSERT INTO public.transactions(
    id,reference_no,transaction_type,status,warehouse_id,storage_area_id,
    external_reference,supplier,receiver_name,notes,created_by,recipient_department_id,adjustment_reason
  ) VALUES (
    p_transaction_id,btrim(p_transaction->>'reference_no'),v_type,'PENDING_APPROVAL',v_warehouse_id,
    NULLIF(p_transaction->>'storage_area_id','')::uuid,
    NULLIF(p_transaction->>'external_reference',''),NULLIF(p_transaction->>'supplier',''),
    NULLIF(p_transaction->>'receiver_name',''),NULLIF(p_transaction->>'notes',''),v_user_id,NULLIF(p_transaction->>'recipient_department_id','')::uuid,NULLIF(btrim(p_transaction->>'adjustment_reason'),'')
  );

  INSERT INTO public.transaction_lines(
    id,transaction_id,item_id,shelf_id,storage_area_id,administrative_department_id,quantity,batch_no,expiry_date,notes
  )
  SELECT x.id,p_transaction_id,x.item_id,x.shelf_id,COALESCE(x.storage_area_id,sh.storage_area_id),x.administrative_department_id,x.quantity,
         NULLIF(x.batch_no,''),x.expiry_date,x.notes
  FROM jsonb_to_recordset(p_lines) AS x(
    id uuid,item_id uuid,shelf_id uuid,storage_area_id uuid,administrative_department_id uuid,quantity numeric,batch_no text,expiry_date date,notes text
  )
  JOIN public.shelves sh ON sh.id=x.shelf_id;

  RETURN jsonb_build_object('transaction_id',p_transaction_id,'status','PENDING_APPROVAL','already_created',false);
END;
$function$

;
CREATE OR REPLACE FUNCTION public.create_stocktake_session_with_lines(p_warehouse_id uuid, p_storage_area_id uuid DEFAULT NULL::uuid, p_stocktake_type text DEFAULT 'CYCLE'::text, p_count_mode text DEFAULT 'ANNOUNCED'::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_session_id uuid;
  v_count integer;
  v_area public.storage_areas%ROWTYPE;
  v_assigned uuid[];
BEGIN
  IF v_user_id IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'An active authenticated user is required';
  END IF;
  IF NOT public.current_user_has_permission('action:stocktake:start') THEN
    RAISE EXCEPTION 'You do not have permission to start stocktake sessions';
  END IF;
  IF p_warehouse_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.warehouses WHERE id=p_warehouse_id) THEN
    RAISE EXCEPTION 'A valid warehouse is required';
  END IF;
  IF NOT public.current_user_can_access_warehouse(p_warehouse_id) THEN
    RAISE EXCEPTION 'You cannot start a stocktake outside your assigned warehouses' USING ERRCODE='42501';
  END IF;
  IF p_stocktake_type NOT IN ('FULL','CYCLE','SURPRISE','RECOUNT') THEN RAISE EXCEPTION 'Invalid stocktake type'; END IF;
  IF p_count_mode NOT IN ('ANNOUNCED','BLIND','VISIBLE') THEN RAISE EXCEPTION 'Invalid stocktake count mode'; END IF;
  IF p_storage_area_id IS NOT NULL THEN
    SELECT * INTO v_area FROM public.storage_areas a
    WHERE a.id=p_storage_area_id AND a.warehouse_id=p_warehouse_id AND COALESCE(a.is_active,true)=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Storage area is invalid, inactive, or belongs to another warehouse'; END IF;
  END IF;
  INSERT INTO public.stocktake_sessions
    (warehouse_id,storage_area_id,status,created_by,notes,stocktake_type,count_mode,scope_type)
  VALUES
    (p_warehouse_id,p_storage_area_id,'IN_PROGRESS',v_user_id,p_notes,p_stocktake_type,
     CASE WHEN p_count_mode='VISIBLE' THEN 'ANNOUNCED' ELSE p_count_mode END,
     CASE WHEN p_storage_area_id IS NULL THEN 'WAREHOUSE' ELSE 'STORAGE_AREA' END)
  RETURNING id INTO v_session_id;
  v_count := public.populate_stocktake_session_lines_internal(v_session_id);
  RETURN jsonb_build_object('success',true,'session_id',v_session_id,'line_count',v_count,
    'stocktake_type',p_stocktake_type,'count_mode',CASE WHEN p_count_mode='VISIBLE' THEN 'ANNOUNCED' ELSE p_count_mode END,
    'scope_type',CASE WHEN p_storage_area_id IS NULL THEN 'WAREHOUSE' ELSE 'STORAGE_AREA' END);
END;
$function$

;
CREATE OR REPLACE FUNCTION public.save_stocktake_count(p_line_id uuid, p_counted_qty numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$ DECLARE v_user uuid:=auth.uid(); v_line public.stocktake_lines%ROWTYPE; v_session public.stocktake_sessions%ROWTYPE; v_assigned uuid[]; BEGIN IF v_user IS NULL OR NOT public.current_user_is_active() THEN RAISE EXCEPTION 'Active authenticated user required'; END IF; IF p_counted_qty IS NULL OR p_counted_qty<0 OR p_counted_qty::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'Count must be a finite non-negative number'; END IF; SELECT * INTO v_line FROM public.stocktake_lines WHERE id=p_line_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Line not found'; END IF; SELECT * INTO v_session FROM public.stocktake_sessions WHERE id=v_line.session_id FOR UPDATE; IF v_session.status<>'IN_PROGRESS' OR v_session.review_status NOT IN ('DRAFT','REJECTED') OR COALESCE(v_line.is_settled,false) THEN RAISE EXCEPTION 'Session is locked'; END IF; IF NOT public.current_user_has_permission('action:stocktake:count') AND NOT public.current_user_has_permission('action:stocktake:start') THEN RAISE EXCEPTION 'Count permission required'; END IF; SELECT assigned_warehouse_ids INTO v_assigned FROM public.profiles WHERE id=v_user; IF NOT public.current_user_can_access_warehouse(v_session.warehouse_id) THEN RAISE EXCEPTION 'Warehouse not assigned' USING ERRCODE='42501'; END IF; UPDATE public.stocktake_lines SET counted_qty=p_counted_qty WHERE id=p_line_id; RETURN jsonb_build_object('success',true,'line_id',p_line_id,'counted_qty',p_counted_qty); END; $function$

;
CREATE OR REPLACE FUNCTION public.submit_stocktake_for_review(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE v_user uuid:=auth.uid(); v_s public.stocktake_sessions%ROWTYPE; v_total integer; v_counted integer; v_assigned uuid[];
BEGIN
 IF v_user IS NULL OR NOT public.current_user_is_active() THEN RAISE EXCEPTION 'Active authenticated user required'; END IF;
 IF NOT public.current_user_has_permission('action:stocktake:submit') AND NOT public.current_user_has_permission('action:stocktake:start') THEN RAISE EXCEPTION 'Submit permission required'; END IF;
 SELECT * INTO v_s FROM public.stocktake_sessions WHERE id=p_session_id FOR UPDATE;
 IF NOT FOUND OR v_s.status<>'IN_PROGRESS' THEN RAISE EXCEPTION 'Only in-progress sessions can be submitted'; END IF;
 IF v_s.review_status NOT IN ('DRAFT','REJECTED') THEN RAISE EXCEPTION 'Session already submitted'; END IF;
 SELECT assigned_warehouse_ids INTO v_assigned FROM public.profiles WHERE id=v_user;
 IF NOT public.current_user_can_access_warehouse(v_s.warehouse_id) THEN RAISE EXCEPTION 'Warehouse not assigned' USING ERRCODE='42501'; END IF;
 SELECT count(*),count(*) FILTER (WHERE counted_qty IS NOT NULL) INTO v_total,v_counted FROM public.stocktake_lines WHERE session_id=p_session_id;
 IF v_total=0 OR v_total<>v_counted THEN RAISE EXCEPTION 'All stocktake lines must be counted before submission'; END IF;
 UPDATE public.stocktake_sessions SET review_status='PENDING_REVIEW',submitted_by=v_user,submitted_at=now(),reviewed_by=NULL,reviewed_at=NULL,review_comment=NULL WHERE id=p_session_id;
 RETURN jsonb_build_object('success',true,'session_id',p_session_id,'review_status','PENDING_REVIEW','lines_counted',v_counted);
END; $function$

;
CREATE OR REPLACE FUNCTION public.review_stocktake_session(p_session_id uuid, p_approve boolean, p_comment text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_s public.stocktake_sessions%ROWTYPE;
  v_assigned uuid[];
BEGIN
  IF v_user IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'Active authenticated user required';
  END IF;

  IF NOT public.current_user_has_permission('action:stocktake:approve')
     AND NOT public.current_user_is_manager() THEN
    RAISE EXCEPTION 'Approval permission required';
  END IF;

  SELECT * INTO v_s
  FROM public.stocktake_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  IF NOT FOUND OR v_s.status <> 'IN_PROGRESS' THEN
    RAISE EXCEPTION 'Session not found or not in progress';
  END IF;

  IF v_s.review_status <> 'PENDING_REVIEW' THEN
    RAISE EXCEPTION 'Only pending sessions can be reviewed';
  END IF;

  IF v_s.created_by = v_user OR v_s.submitted_by = v_user THEN
    RAISE EXCEPTION 'Creator/submitter cannot approve own session';
  END IF;

  SELECT assigned_warehouse_ids INTO v_assigned
  FROM public.profiles
  WHERE id = v_user AND status = 'ACTIVE';

  IF NOT public.current_user_can_access_warehouse(v_s.warehouse_id) THEN
    RAISE EXCEPTION 'You cannot review a stocktake outside your assigned warehouses' USING ERRCODE='42501';
  END IF;

  UPDATE public.stocktake_sessions
  SET review_status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
      reviewed_by = v_user,
      reviewed_at = now(),
      review_comment = NULLIF(trim(COALESCE(p_comment, '')), '')
  WHERE id = p_session_id;

  RETURN jsonb_build_object(
    'success', true,
    'session_id', p_session_id,
    'review_status', CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END
  );
END;
$function$

;
CREATE OR REPLACE FUNCTION public.process_stocktake_settlement_with_direction(p_session_id uuid, p_line_ids uuid[], p_direction text, p_line_comments jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_s public.stocktake_sessions%ROWTYPE;
  v_user uuid := auth.uid();
  v_assigned uuid[];
  v_start timestamptz;
BEGIN
  IF v_user IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'Active authenticated user required';
  END IF;

  IF NOT public.current_user_has_permission('action:stocktake:settle') THEN
    RAISE EXCEPTION 'Settlement permission required';
  END IF;

  IF p_direction IS NULL OR p_direction NOT IN ('INCREASE','DECREASE') THEN
    RAISE EXCEPTION 'Settlement direction must be INCREASE or DECREASE';
  END IF;

  SELECT * INTO v_s
  FROM public.stocktake_sessions
  WHERE id = p_session_id
  FOR UPDATE;

  IF NOT FOUND OR v_s.status IS DISTINCT FROM 'IN_PROGRESS' THEN
    RAISE EXCEPTION 'Session not in progress';
  END IF;

  -- Null or any non-approved review state must never pass settlement.
  IF v_s.review_status IS DISTINCT FROM 'APPROVED' THEN
    RAISE EXCEPTION 'Session must be approved before settlement';
  END IF;

  SELECT assigned_warehouse_ids INTO v_assigned
  FROM public.profiles
  WHERE id = v_user;

  IF NOT public.current_user_can_access_warehouse(v_s.warehouse_id) THEN
    RAISE EXCEPTION 'Warehouse not assigned' USING ERRCODE='42501';
  END IF;

  IF p_line_ids IS NULL OR cardinality(p_line_ids) = 0 THEN
    RAISE EXCEPTION 'Select stocktake lines';
  END IF;

  v_start := COALESCE(v_s.count_started_at, v_s.created_at);

  IF EXISTS (
    SELECT 1
    FROM public.stocktake_lines l
    JOIN public.transaction_lines tl
      ON tl.item_id = l.item_id
     AND tl.shelf_id = l.shelf_id
     AND COALESCE(tl.batch_no, '') = COALESCE(l.batch_no, '')
    JOIN public.transactions t ON t.id = tl.transaction_id
    WHERE l.session_id = p_session_id
      AND l.id = ANY(p_line_ids)
      AND t.status = 'APPROVED'
      AND t.created_at > v_start
  ) OR EXISTS (
    SELECT 1
    FROM public.stocktake_lines l
    JOIN public.stock st
      ON st.item_id = l.item_id
     AND st.shelf_id = l.shelf_id
     AND COALESCE(st.batch_no, '') = COALESCE(l.batch_no, '')
    WHERE l.session_id = p_session_id
      AND l.id = ANY(p_line_ids)
      AND st.updated_at > v_start
  ) THEN
    RAISE EXCEPTION 'Stock movements occurred after the count started. Recount affected lines before settlement';
  END IF;

  RETURN public.process_stocktake_settlement_direct_internal_with_direction(
    p_session_id,
    p_line_ids,
    p_direction,
    COALESCE(p_line_comments, '{}'::jsonb)
  );
END;
$function$

;
COMMIT;
