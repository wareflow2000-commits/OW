-- ORSHAP WMS v13.9.58
-- Fingerprint offline-sync payloads to detect operation_id reuse with changed content.
-- Existing legacy sync records without a fingerprint remain non-mutating on retries;
-- new records detect same operation_id reused with different payload.
BEGIN;
CREATE OR REPLACE FUNCTION public.process_sync_batch_v2_impl(p_device_id text, p_operations jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_op jsonb;
  v_results jsonb := '[]'::jsonb;
  v_user_id uuid := (SELECT auth.uid());
  v_user_role text;
  v_user_status text;
  v_assigned_warehouses uuid[];
  v_operation_id uuid;
  v_log_id uuid;
  v_existing_status text;
  v_existing_details jsonb;
  v_payload_hash text;
  v_operation_type text;
  v_permission text;
  v_item_id uuid;
  v_shelf_id uuid;
  v_warehouse_id uuid;
  v_transaction_id uuid;
  v_line_id uuid;
  v_base_version integer;
  v_delta numeric;
  v_new_qty numeric;
  v_old_qty numeric := 0;
  v_new_version integer;
  v_server_version integer;
  v_batch_no text;
  v_expiry_date date;
  v_unit text;
  v_reference text;
  v_item record;
  v_shelf record;
  v_stock record;
  v_tx_exists boolean;
  v_error text;
  v_result_status text;
  v_header jsonb;
  v_notes text;
  v_storage_area_id uuid;
  v_owner uuid;
  v_owner_count integer := 0;
BEGIN
  IF v_user_id IS NULL OR NOT (SELECT public.current_user_is_active()) THEN
    RAISE EXCEPTION 'An active authenticated user is required for synchronization';
  END IF;
  IF p_device_id IS NULL OR length(btrim(p_device_id)) = 0 OR length(p_device_id) > 128 THEN
    RAISE EXCEPTION 'A valid device_id is required';
  END IF;
  IF p_operations IS NULL OR jsonb_typeof(p_operations) <> 'array' THEN
    RAISE EXCEPTION 'p_operations must be a JSON array';
  END IF;

  SELECT p.role, p.status, COALESCE(p.assigned_warehouse_ids, ARRAY[]::uuid[])
    INTO v_user_role, v_user_status, v_assigned_warehouses
  FROM public.profiles p WHERE p.id = v_user_id;
  IF v_user_status <> 'ACTIVE' THEN RAISE EXCEPTION 'User account is not active'; END IF;

  FOR v_op IN SELECT value FROM jsonb_array_elements(p_operations) AS x(value)
  LOOP
    v_operation_id := NULL;
    v_log_id := NULL;
    v_operation_type := COALESCE(v_op->>'operation_type','');

    BEGIN
      v_operation_id := NULLIF(v_op->>'operation_id','')::uuid;
      IF v_operation_id IS NULL THEN
        RAISE EXCEPTION 'operation_id must be a UUID';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'operation_id', v_op->>'operation_id', 'status', 'ERROR',
        'error', 'Each operation requires a valid UUID operation_id'
      ));
      CONTINUE;
    END;

    v_payload_hash := md5(v_op::text);

    INSERT INTO public.sync_log(device_id, batch_id, status, details)
    VALUES (p_device_id, v_operation_id, 'PROCESSING',
            jsonb_build_object('operation_id',v_operation_id,'operation_type',v_operation_type,'user_id',v_user_id,'payload_hash',v_payload_hash))
    ON CONFLICT (device_id, batch_id) DO NOTHING
    RETURNING id INTO v_log_id;

    IF v_log_id IS NULL THEN
      SELECT sl.id, sl.status, sl.details INTO v_log_id, v_existing_status, v_existing_details
      FROM public.sync_log sl
      WHERE sl.device_id = p_device_id AND sl.batch_id = v_operation_id
      FOR UPDATE;

      IF v_existing_details ? 'payload_hash' AND v_existing_details->>'payload_hash' IS DISTINCT FROM v_payload_hash THEN
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'operation_id', v_operation_id, 'status', 'CONFLICT',
          'error', 'operation_id was already used with a different payload'
        ));
        CONTINUE;
      ELSIF v_existing_status = 'SUCCESS' THEN
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'operation_id', v_operation_id, 'status', 'ALREADY_PROCESSED',
          'payload_conflict_check', CASE WHEN v_existing_details ? 'payload_hash' THEN 'verified' ELSE 'unavailable_legacy_record' END
        ));
        CONTINUE;
      ELSIF v_existing_status = 'PROCESSING' THEN
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'operation_id', v_operation_id, 'status', 'IN_PROGRESS'
        ));
        CONTINUE;
      ELSE
        UPDATE public.sync_log
        SET status = 'PROCESSING',
            details = jsonb_build_object('operation_id',v_operation_id,'operation_type',v_operation_type,
                                         'user_id',v_user_id,'payload_hash',v_payload_hash,'retry',true)
        WHERE id = v_log_id;
      END IF;
    END IF;

    BEGIN
      IF v_operation_type IN ('STOCKTAKE','OPENING_BALANCE') THEN
        RAISE EXCEPTION '% must use its approved accounting workflow and cannot be posted directly by offline sync',
          v_operation_type;
      END IF;

      IF v_operation_type NOT IN ('ISSUE','GRN','ADJUSTMENT_IN','ADJUSTMENT_OUT',
                                  'STOCKTAKE','OPENING_BALANCE','RETURN_FROM_USAGE') THEN
        RAISE EXCEPTION 'Unsupported operation_type: %', v_operation_type;
      END IF;

      v_permission := CASE v_operation_type
        WHEN 'ISSUE' THEN 'action:transaction:issue:create'
        WHEN 'RETURN_FROM_USAGE' THEN 'action:transaction:grn:create'
        WHEN 'GRN' THEN 'action:transaction:grn:create'
        WHEN 'OPENING_BALANCE' THEN 'action:transaction:adjustment:create'
        WHEN 'ADJUSTMENT_IN' THEN 'action:transaction:adjustment:create'
        WHEN 'ADJUSTMENT_OUT' THEN 'action:transaction:adjustment:create'
        WHEN 'STOCKTAKE' THEN 'action:stocktake:settle'
      END;
      IF NOT (SELECT public.current_user_has_permission(v_permission)) THEN
        RAISE EXCEPTION 'Permission denied for operation type %', v_operation_type;
      END IF;

      -- Offline sync must enforce the same privileged opening-balance rule as the online transaction path.
      IF v_operation_type = 'OPENING_BALANCE'
         AND v_user_role NOT IN ('SUPER_ADMIN', 'MANAGER') THEN
        RAISE EXCEPTION 'Only a manager or super administrator may create an opening balance';
      END IF;

      v_item_id := NULLIF(v_op->>'item_id','')::uuid;
      v_shelf_id := NULLIF(v_op->>'shelf_id','')::uuid;
      v_warehouse_id := NULLIF(v_op->>'warehouse_id','')::uuid;
      v_transaction_id := COALESCE(NULLIF(v_op->>'transaction_id','')::uuid, v_operation_id);
      v_line_id := COALESCE(NULLIF(v_op->>'line_id','')::uuid, v_operation_id);
      v_base_version := COALESCE(NULLIF(v_op->>'base_version','')::integer, 0);
      v_batch_no := COALESCE(v_op->>'batch_no','');
      v_expiry_date := NULLIF(v_op->>'expiry_date','')::date;
      v_unit := COALESCE(NULLIF(v_op->>'unit',''),'');
      v_reference := COALESCE(NULLIF(v_op->>'reference_no',''),
                              NULLIF(v_op->>'source_ref',''),
                              v_operation_id::text);
      v_header := COALESCE(v_op->'header', '{}'::jsonb);
      v_owner := COALESCE(NULLIF(v_op->>'administrative_department_id','')::uuid, NULLIF(v_header->>'administrative_department_id','')::uuid);
      v_notes := COALESCE(NULLIF(v_op->>'notes',''), NULLIF(v_header->>'notes',''));

      IF v_item_id IS NULL OR v_shelf_id IS NULL OR v_warehouse_id IS NULL THEN
        RAISE EXCEPTION 'item_id, shelf_id, and warehouse_id are required';
      END IF;
      IF v_base_version < 0 THEN RAISE EXCEPTION 'base_version cannot be negative'; END IF;

      SELECT s.id, s.warehouse_id, s.storage_area_id, s.default_administrative_department_id
        INTO v_shelf FROM public.shelves s WHERE s.id = v_shelf_id;
      IF NOT FOUND THEN RAISE EXCEPTION 'Shelf not found'; END IF;
      IF v_shelf.warehouse_id <> v_warehouse_id THEN
        RAISE EXCEPTION 'Shelf does not belong to the submitted warehouse';
      END IF;
      
                  IF v_user_role NOT IN ('SUPER_ADMIN','MANAGER','ADMIN')
                     AND NOT (
                          v_warehouse_id = ANY(
                                 COALESCE(v_assigned_warehouses, ARRAY[]::uuid[])
                                      )
                                         )
                                         THEN
                                           RAISE EXCEPTION 'User is not assigned to the requested warehouse';
                                           END IF;
                                           
      SELECT i.id, i.code, i.name_en, i.base_unit INTO v_item
        FROM public.items i WHERE i.id = v_item_id;
      IF NOT FOUND THEN RAISE EXCEPTION 'Item not found'; END IF;

      IF NULLIF(v_op->>'quantity_change','') IS NULL THEN
        RAISE EXCEPTION 'quantity_change is required';
      END IF;
      v_delta := (v_op->>'quantity_change')::numeric;
      IF v_delta = 0 THEN RAISE EXCEPTION 'quantity_change cannot be zero'; END IF;
      IF v_operation_type IN ('ISSUE','ADJUSTMENT_OUT') THEN
        v_delta := -abs(v_delta);
      ELSE
        v_delta := abs(v_delta);
      END IF;

      v_storage_area_id := COALESCE(NULLIF(v_header->>'storage_area_id','')::uuid, v_shelf.storage_area_id);
      IF v_storage_area_id IS NULL OR v_storage_area_id IS DISTINCT FROM v_shelf.storage_area_id THEN
        RAISE EXCEPTION 'Submitted storage area does not match the selected shelf';
      END IF;

      -- Serialize owner resolution and stock version checks for this item/shelf/batch.
      PERFORM pg_advisory_xact_lock(hashtextextended(v_item_id::text||':'||v_shelf_id::text||':'||v_batch_no,0));
      IF v_owner IS NULL THEN
        SELECT count(*), (array_agg(owner_id ORDER BY owner_id NULLS FIRST))[1]
          INTO v_owner_count, v_owner
          FROM (SELECT s.administrative_department_id AS owner_id
                  FROM public.stock s
                 WHERE s.item_id=v_item_id AND s.shelf_id=v_shelf_id AND s.batch_no=v_batch_no
                 GROUP BY s.administrative_department_id) owners;
        IF v_owner_count > 1 THEN
          RAISE EXCEPTION 'Stock-owning department is required when multiple owners have balances at this location';
        ELSIF v_owner_count = 0 THEN
          v_owner := v_shelf.default_administrative_department_id;
          IF v_owner IS NULL THEN RAISE EXCEPTION 'Stock-owning department is required for an offline inbound operation'; END IF;
        END IF;
      END IF;
      IF v_owner IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.administrative_departments d WHERE d.id=v_owner AND d.is_active=true) THEN
        RAISE EXCEPTION 'Stock-owning department is missing or inactive';
      END IF;

      SELECT s.* INTO v_stock FROM public.stock s
        WHERE s.item_id = v_item_id
          AND s.shelf_id = v_shelf_id
          AND s.batch_no = v_batch_no
          AND s.administrative_department_id IS NOT DISTINCT FROM v_owner
        FOR UPDATE;

      IF NOT FOUND THEN
        v_old_qty := 0;
        IF v_operation_type NOT IN ('GRN','ADJUSTMENT_IN','STOCKTAKE','OPENING_BALANCE','RETURN_FROM_USAGE')
           OR v_base_version <> 0 THEN
          RAISE EXCEPTION 'VERSION_CONFLICT: expected version %, current version %, balance %',
            v_base_version, 0, 0;
        END IF;
        v_new_qty := v_delta;
        IF v_new_qty < 0 THEN RAISE EXCEPTION 'Insufficient stock for operation'; END IF;
        v_new_version := 1;
        INSERT INTO public.stock(item_id,shelf_id,administrative_department_id,storage_area_id,quantity,updated_at,created_at,batch_no,expiry_date,version)
        VALUES(v_item_id,v_shelf_id,v_owner,v_storage_area_id,v_new_qty,NOW(),NOW(),v_batch_no,v_expiry_date,v_new_version);
      ELSE
        v_old_qty := COALESCE(v_stock.quantity,0);
        v_server_version := COALESCE(v_stock.version,1);
        IF v_server_version <> v_base_version THEN
          RAISE EXCEPTION 'VERSION_CONFLICT: expected version %, current version %, balance %',
            v_base_version, v_server_version, v_old_qty;
        END IF;
        v_new_qty := v_old_qty + v_delta;
        IF v_new_qty < 0 THEN RAISE EXCEPTION 'Insufficient stock for operation'; END IF;
        v_new_version := v_server_version + 1;
        UPDATE public.stock
        SET quantity = v_new_qty,
            version = v_new_version,
            expiry_date = COALESCE(v_expiry_date, expiry_date),
            storage_area_id = COALESCE(storage_area_id, v_storage_area_id),
            updated_at = NOW()
        WHERE id = v_stock.id;
      END IF;

      SELECT EXISTS(SELECT 1 FROM public.transactions WHERE id = v_transaction_id) INTO v_tx_exists;
      IF NOT v_tx_exists THEN
        INSERT INTO public.transactions(
          id, reference_no, transaction_type, status, warehouse_id, storage_area_id,
          external_reference, supplier, receiver_name, notes, created_by, created_at
        ) VALUES (
          v_transaction_id, v_reference, v_operation_type, 'APPROVED', v_warehouse_id,
          v_storage_area_id,
          NULLIF(v_header->>'external_reference',''), NULLIF(v_header->>'supplier',''),
          NULLIF(v_header->>'receiver_name',''), v_notes, v_user_id,
          COALESCE(NULLIF(v_header->>'created_at','')::timestamptz, NOW())
        );
      END IF;

      
            INSERT INTO public.transaction_lines(
              id, transaction_id, item_id, shelf_id, administrative_department_id, storage_area_id, quantity, batch_no,
                expiry_date, notes, balance_before, balance_after, created_at
                ) VALUES (
                  v_line_id, v_transaction_id, v_item_id, v_shelf_id, v_owner, v_storage_area_id, ABS(v_delta),
                    NULLIF(v_batch_no,''), v_expiry_date, v_notes, v_old_qty, v_new_qty, NOW()
                    )
                    ON CONFLICT (id) DO NOTHING;

                    IF NOT FOUND THEN
                      RAISE EXCEPTION
                          'SYNC_LINE_CONFLICT: transaction line ID already exists; operation was not posted';
                          END IF;
                          
      INSERT INTO public.transaction_ledger(
        transaction_id, ledger_type, user_id, warehouse_id, administrative_department_id, shelf_id,
        storage_area_id, item_id, quantity, balance_before, balance_after, transaction_type,
        details, reference, approved, approved_at
      ) VALUES (
        v_transaction_id, 'TRANSACTION', v_user_id, v_warehouse_id, v_owner,
        v_shelf_id, v_storage_area_id, v_item_id, v_delta,
        v_old_qty, v_new_qty, v_operation_type,
        jsonb_build_object('tx_line_id', v_line_id, 'notes', v_notes,
                           'sync_device_id', p_device_id, 'operation_id', v_operation_id,
                           'base_version', v_base_version, 'result_version', v_new_version,
                           'administrative_department_id', v_owner, 'storage_area_id', v_storage_area_id,
                           'posted_via', 'process_sync_batch_v2'),
        v_reference, true, NOW()
      );

      INSERT INTO public.inventory_ledger(
        occurred_at, item_id, item_code, item_name, warehouse_id, administrative_department_id,
        shelf_id, storage_area_id, delta, unit, source_type, source_id, source_ref,
        running_balance, created_by, notes, metadata, created_at, is_opening_balance,
        batch_no, expiry_date
      ) VALUES (
        COALESCE(NULLIF(v_header->>'occurred_at','')::timestamptz, NOW()),
        v_item_id, v_item.code, v_item.name_en, v_warehouse_id, v_owner,
        v_shelf_id, v_storage_area_id, v_delta,
        COALESCE(NULLIF(v_unit,''), v_item.base_unit, 'PCS'),
        v_operation_type, v_transaction_id, v_reference, v_new_qty, v_user_id, v_notes,
        jsonb_build_object('tx_line_id', v_line_id, 'sync_device_id', p_device_id,
                           'operation_id', v_operation_id, 'base_version', v_base_version,
                           'administrative_department_id', v_owner, 'storage_area_id', v_storage_area_id,
                           'result_version', v_new_version),
        NOW(), (v_operation_type = 'OPENING_BALANCE'), NULLIF(v_batch_no,''), v_expiry_date
      );

      INSERT INTO public.audit_logs(
        user_id, action, entity, entity_id, item_id, item_code, item_name,
        warehouse_id, quantity_before, quantity_after, reference, details
      ) VALUES (
        v_user_id, 'OFFLINE_POST', 'TRANSACTION', v_transaction_id::text,
        v_item_id, v_item.code, v_item.name_en, v_warehouse_id,
        v_old_qty, v_new_qty, v_reference,
        jsonb_build_object('operation_id', v_operation_id, 'operation_type', v_operation_type,
                           'device_id', p_device_id, 'delta', v_delta, 'administrative_department_id', v_owner, 'offline', true)
      );

      UPDATE public.sync_log
      SET status = 'SUCCESS',
          details = jsonb_build_object('operation_id', v_operation_id, 'operation_type', v_operation_type,
                                       'item_id', v_item_id, 'shelf_id', v_shelf_id, 'delta', v_delta,
                                       'administrative_department_id', v_owner, 'storage_area_id', v_storage_area_id,
                                       'balance_after', v_new_qty, 'version_after', v_new_version,
                                       'transaction_id', v_transaction_id, 'user_id', v_user_id,
                                       'payload_hash', v_payload_hash)
      WHERE id = v_log_id;

      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'operation_id', v_operation_id, 'status', 'SUCCESS',
        'balance_after', v_new_qty, 'version_after', v_new_version,
        'transaction_id', v_transaction_id, 'line_id', v_line_id
      ));
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      v_result_status := CASE WHEN v_error LIKE 'VERSION_CONFLICT:%' THEN 'CONFLICT' ELSE 'ERROR' END;
      UPDATE public.sync_log
      SET status = v_result_status,
          details = jsonb_build_object('operation_id', v_operation_id, 'operation_type', v_operation_type,
                                       'user_id', v_user_id, 'error', v_error, 'payload_hash', v_payload_hash)
      WHERE id = v_log_id;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'operation_id', v_operation_id, 'status', v_result_status, 'error', v_error
      ));
    END;
  END LOOP;

  RETURN v_results;
END;
$function$

COMMIT;
