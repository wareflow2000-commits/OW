-- ORSHAP WMS v13.9.58
-- Repair stocktake settlement after stock ownership became part of the stock key.
-- Preserve the accounting owner on both transaction_lines and stock. A physical
-- stocktake line aggregates owners; if a non-zero variance spans multiple owners,
-- fail safely instead of allocating it to an arbitrary department.
BEGIN;

CREATE OR REPLACE FUNCTION public.process_stocktake_settlement_direct_internal_with_direction(p_session_id uuid, p_line_ids uuid[], p_direction text, p_line_comments jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_session public.stocktake_sessions%ROWTYPE;
  v_line public.stocktake_lines%ROWTYPE;
  v_tx_id uuid;
  v_ref text;
  v_tx_type text;
  v_processed integer := 0;
  v_old_qty numeric;
  v_new_qty numeric;
  v_delta numeric;
  v_selected integer;
  v_eligible integer;
  v_line_comment text;
  v_variance_magnitude numeric;
  v_owner uuid;
  v_owner_count integer := 0;
  v_default_owner uuid;
BEGIN
  IF p_direction IS NULL OR p_direction NOT IN ('INCREASE','DECREASE') THEN RAISE EXCEPTION 'Settlement direction must be INCREASE or DECREASE'; END IF; IF p_session_id IS NULL OR p_line_ids IS NULL OR cardinality(p_line_ids)=0 THEN
    RAISE EXCEPTION 'A session and at least one stocktake line are required';
  END IF;
  SELECT * INTO v_session FROM public.stocktake_sessions WHERE id=p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stocktake session not found'; END IF;
  IF v_session.status <> 'IN_PROGRESS' THEN RAISE EXCEPTION 'Only an IN_PROGRESS stocktake session can be settled'; END IF;

  SELECT count(DISTINCT x) INTO v_selected FROM unnest(p_line_ids) x;
  SELECT count(*) INTO v_eligible FROM public.stocktake_lines
    WHERE id=ANY(p_line_ids) AND session_id=p_session_id AND COALESCE(is_settled,false)=false;
  IF v_selected <> v_eligible THEN
    RAISE EXCEPTION 'One or more selected lines are missing, belong to another session, or are already settled';
  END IF;

  -- A non-zero variance must not race with another stock movement creating a
  -- second owner row after the owner check. Settlement is rare; briefly serialize
  -- stock writes only when at least one selected line changes quantity.
  IF EXISTS (
    SELECT 1 FROM public.stocktake_lines l
    WHERE l.id = ANY(p_line_ids)
      AND l.session_id = p_session_id
      AND abs(COALESCE(l.variance, l.counted_qty - COALESCE(l.system_qty,0))) > 0
  ) THEN
    LOCK TABLE public.stock IN SHARE ROW EXCLUSIVE MODE;
  END IF;

  FOR v_line IN
    SELECT l.* FROM public.stocktake_lines l
    WHERE l.id=ANY(p_line_ids) AND l.session_id=p_session_id
      AND COALESCE(l.is_settled,false)=false
    ORDER BY l.item_id,l.shelf_id,l.batch_no,l.id
    FOR UPDATE
  LOOP
    IF v_line.counted_qty IS NULL OR v_line.counted_qty < 0 THEN
      RAISE EXCEPTION 'Actual count is required and must be non-negative for line %',v_line.id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.items i WHERE i.id=v_line.item_id) THEN
      RAISE EXCEPTION 'Stocktake item % no longer exists',v_line.item_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.shelves sh WHERE sh.id=v_line.shelf_id AND sh.warehouse_id=v_session.warehouse_id) THEN
      RAISE EXCEPTION 'Stocktake shelf % does not belong to the session warehouse',v_line.shelf_id;
    END IF;

    
                                                              -- Serialize stock updates, including when no stock row exists yet.
                                                                  PERFORM pg_advisory_xact_lock(
                                                                        hashtextextended(
                                                                                v_line.item_id::text || ':' ||
                                                                                        v_line.shelf_id::text || ':' ||
                                                                                                COALESCE(v_line.batch_no,''),
                                                                                                        0
                                                                                                              )
                                                                                                                  );

                                                                                                                      -- A missing stock row represents zero quantity.
                                                                                                                          -- Lock all stock rows for this physical item/shelf/batch and sum them.
    -- A stocktake line is physically counted across owners, so a non-zero variance
    -- may only be posted when its accounting owner is unambiguous.
    PERFORM 1
    FROM public.stock s
    WHERE s.item_id = v_line.item_id
      AND s.shelf_id = v_line.shelf_id
      AND s.batch_no = COALESCE(v_line.batch_no,'')
    ORDER BY s.administrative_department_id NULLS FIRST
    FOR UPDATE;

    SELECT count(*), COALESCE(sum(s.quantity),0),
           min(s.administrative_department_id::text)::uuid
      INTO v_owner_count, v_old_qty, v_owner
    FROM public.stock s
    WHERE s.item_id = v_line.item_id
      AND s.shelf_id = v_line.shelf_id
      AND s.batch_no = COALESCE(v_line.batch_no,'');

    v_line_comment := NULLIF(btrim(COALESCE(p_line_comments->>v_line.id::text, '')), '');
    v_variance_magnitude := abs(COALESCE(v_line.variance, v_line.counted_qty-COALESCE(v_line.system_qty,v_old_qty)));
    IF v_variance_magnitude > 0 AND ((p_direction='INCREASE' AND COALESCE(v_line.variance, v_line.counted_qty-COALESCE(v_line.system_qty,v_old_qty))<0) OR (p_direction='DECREASE' AND COALESCE(v_line.variance, v_line.counted_qty-COALESCE(v_line.system_qty,v_old_qty))>0)) AND v_line_comment IS NULL THEN
      RAISE EXCEPTION 'A line comment is required when settlement direction conflicts with the counted variance (line %)', v_line.id;
    END IF;
    v_delta := CASE WHEN p_direction='INCREASE' THEN v_variance_magnitude ELSE -v_variance_magnitude END;

    IF v_delta <> 0 THEN
      IF v_owner_count > 1 THEN
        RAISE EXCEPTION 'Stocktake line % spans multiple owning departments; settle the variance with an owner-specific correction voucher', v_line.id;
      ELSIF v_owner_count = 0 THEN
        SELECT sh.default_administrative_department_id INTO v_default_owner
        FROM public.shelves sh WHERE sh.id = v_line.shelf_id;
        v_owner := v_default_owner;
      END IF;

      IF v_owner IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.administrative_departments d
        WHERE d.id = v_owner AND d.is_active = true
      ) THEN
        RAISE EXCEPTION 'Stocktake variance for line % requires one active owning department', v_line.id;
      END IF;

      -- Keep all stock writes serialized during a variance settlement so a new
      -- owner row cannot appear between owner validation and the upsert.
      -- The lock is acquired before the row locks above by the enclosing caller.
      PERFORM pg_advisory_xact_lock(hashtextextended(
        v_line.item_id::text || ':' || v_line.shelf_id::text || ':' ||
        COALESCE(v_line.batch_no,'') || ':' || v_owner::text, 0
      ));

      SELECT COALESCE(s.quantity,0) INTO v_old_qty
      FROM public.stock s
      WHERE s.item_id = v_line.item_id
        AND s.shelf_id = v_line.shelf_id
        AND s.batch_no = COALESCE(v_line.batch_no,'')
        AND s.administrative_department_id IS NOT DISTINCT FROM v_owner
      FOR UPDATE;
      v_old_qty := COALESCE(v_old_qty,0);
    END IF;

    v_new_qty := v_old_qty + v_delta;
    IF v_new_qty < 0 THEN RAISE EXCEPTION 'Settlement would create negative stock for line %',v_line.id; END IF;
    v_tx_id := NULL;
    v_tx_type := NULL;

    IF v_delta <> 0 THEN
      v_tx_id := gen_random_uuid();
      v_ref := 'STK-' || CASE WHEN v_delta>0 THEN 'GAIN-' ELSE 'LOSS-' END ||
               to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS') || '-' || left(replace(v_tx_id::text,'-',''),8);
      v_tx_type := CASE WHEN v_delta>0 THEN 'ADJUSTMENT_IN' ELSE 'ADJUSTMENT_OUT' END;

      INSERT INTO public.transactions
        (id,transaction_type,status,created_by,reference_no,warehouse_id,storage_area_id,notes)
      VALUES
        (v_tx_id,v_tx_type,'APPROVED',v_user_id,v_ref,v_session.warehouse_id,
         v_session.storage_area_id,COALESCE(v_line_comment,'Stocktake settlement ('||p_direction||')'));

      INSERT INTO public.transaction_lines
        (transaction_id,item_id,shelf_id,administrative_department_id,quantity,balance_before,balance_after,batch_no,expiry_date,storage_area_id,notes)
      VALUES
        (v_tx_id,v_line.item_id,v_line.shelf_id,v_owner,abs(v_delta),v_old_qty,v_new_qty,
         COALESCE(v_line.batch_no,''),v_line.expiry_date,v_session.storage_area_id,
         'Stocktake line '||v_line.id::text||CASE WHEN v_line_comment IS NULL THEN '' ELSE '; '||v_line_comment END);

      INSERT INTO public.stock
        (item_id,shelf_id,administrative_department_id,quantity,updated_at,created_at,batch_no,expiry_date,storage_area_id)
      VALUES
        (v_line.item_id,v_line.shelf_id,v_owner,v_new_qty,now(),now(),COALESCE(v_line.batch_no,''),
         v_line.expiry_date,v_session.storage_area_id)
      ON CONFLICT (item_id,shelf_id,batch_no,administrative_department_id)
      DO UPDATE SET quantity=EXCLUDED.quantity,
                    expiry_date=COALESCE(EXCLUDED.expiry_date,public.stock.expiry_date),
                    storage_area_id=COALESCE(EXCLUDED.storage_area_id,public.stock.storage_area_id),
                    updated_at=now();

      INSERT INTO public.stocktake_logs(session_id,item_id,variance,action)
      VALUES (p_session_id,v_line.item_id,v_delta,'ADJUSTED');

      PERFORM public.log_transaction_ledger(
        p_transaction_id:=v_tx_id,
        p_ledger_type:='STOCKTAKE',
        p_user_id:=v_user_id,
        p_warehouse_id:=v_session.warehouse_id,
        p_zone_id:=NULL::uuid,
        p_section_id:=NULL,
        p_shelf_id:=v_line.shelf_id,
        p_item_id:=v_line.item_id,
        p_quantity:=v_delta,
        p_balance_before:=v_old_qty,
        p_balance_after:=v_new_qty,
        p_transaction_type:=v_tx_type,
        p_details:=jsonb_build_object('session_id',p_session_id,'line_id',v_line.id,
          'dynamic_variance_applied',v_delta,'snapshot_variance',v_line.variance,'settlement_direction',p_direction,
          'administrative_department_id',v_owner,'comment',v_line_comment),
        p_reference:=v_ref,
        p_approved:=true,
        p_reference_type:='STOCKTAKE',
        p_batch_no:=COALESCE(v_line.batch_no,''),
        p_expiry_date:=v_line.expiry_date
      );
    ELSE
      INSERT INTO public.stocktake_logs(session_id,item_id,variance,action)
      VALUES (p_session_id,v_line.item_id,0,'MATCHED');
    END IF;

    INSERT INTO public.audit_logs(user_id,action,entity,entity_id,details)
    VALUES (v_user_id,'STOCKTAKE_SETTLEMENT','ITEM',v_line.item_id::text,
      jsonb_strip_nulls(jsonb_build_object('session_id',p_session_id,'tx_id',v_tx_id,
        'delta',v_delta,'system_qty_at_settlement',v_old_qty,
        'counted_qty_at_settlement',v_new_qty,'batch_no',COALESCE(v_line.batch_no,''),
        'shelf_id',v_line.shelf_id,'settlement_direction',p_direction,'comment',v_line_comment)));

    UPDATE public.stocktake_lines
      SET is_settled=true,settled_at=now(),settlement_direction=p_direction,settlement_comment=v_line_comment
      WHERE id=v_line.id;
    v_processed := v_processed+1;
  END LOOP;
  RETURN jsonb_build_object('success',true,'processed',v_processed,'session_id',p_session_id);
END;
$function$;

COMMENT ON FUNCTION public.process_stocktake_settlement_direct_internal_with_direction(uuid,uuid[],text,jsonb)
IS 'Owner-safe stocktake settlement: rejects ambiguous multi-owner variances and writes stock using the owner-aware unique key.';

COMMIT;
