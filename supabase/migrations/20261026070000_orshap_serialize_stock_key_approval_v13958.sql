-- ORSHAP WMS v13.9.58: serialize stock-key posting even when the stock row does not yet exist.
-- This keeps balance_before/balance_after correct for concurrent inbound approvals.
BEGIN;
DO $patch$
DECLARE
  v_body text;
  v_new_body text;
  v_def text;
  v_new_def text;
  v_anchor text := $a$    v_old_qty := 0;
    SELECT s.quantity INTO v_old_qty
    FROM public.stock s
    WHERE s.item_id = v_rec.item_id
      AND s.shelf_id = v_rec.shelf_id
      AND s.batch_no = COALESCE(v_rec.batch_no, '')
      AND s.administrative_department_id IS NOT DISTINCT FROM v_rec.administrative_department_id
    FOR UPDATE;
    v_old_qty := COALESCE(v_old_qty, 0);$a$;
  v_replacement text := $b$    -- Lock the canonical stock key before reading it. FOR UPDATE alone cannot lock
    -- a missing row, so concurrent inbound approvals could otherwise log stale balances.
    PERFORM pg_advisory_xact_lock(hashtextextended(
      v_rec.item_id::text || ':' || v_rec.shelf_id::text || ':' ||
      COALESCE(v_rec.batch_no, '') || ':' || COALESCE(v_rec.administrative_department_id::text, ''),
      0
    ));
    v_old_qty := 0;
    SELECT s.quantity INTO v_old_qty
    FROM public.stock s
    WHERE s.item_id = v_rec.item_id
      AND s.shelf_id = v_rec.shelf_id
      AND s.batch_no = COALESCE(v_rec.batch_no, '')
      AND s.administrative_department_id IS NOT DISTINCT FROM v_rec.administrative_department_id
    FOR UPDATE;
    v_old_qty := COALESCE(v_old_qty, 0);$b$;
  v_count integer;
BEGIN
  SELECT p.prosrc INTO v_body
  FROM pg_proc p
  WHERE p.oid = 'public.approve_transaction(uuid)'::regprocedure;

  v_count := (length(v_body) - length(replace(v_body, v_anchor, ''))) / length(v_anchor);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one stock-key read anchor in approve_transaction, found %', v_count;
  END IF;
  IF position('pg_advisory_xact_lock(hashtextextended' in v_body) > 0 THEN
    RAISE EXCEPTION 'approve_transaction already has a stock-key advisory lock; inspect before reapplying';
  END IF;

  v_new_body := replace(v_body, v_anchor, v_replacement);
  v_def := pg_get_functiondef('public.approve_transaction(uuid)'::regprocedure);
  v_new_def := replace(v_def, v_body, v_new_body);
  IF v_new_def = v_def THEN
    RAISE EXCEPTION 'Could not reconstruct approve_transaction definition';
  END IF;
  EXECUTE v_new_def;
END
$patch$;
DO $scope_patch$
DECLARE
  r record;
  v_body text;
  v_new_body text;
  v_def text;
  v_new_def text;
  v_count integer;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.dispatch_stock_transfer_with_destination_warehouse_owner_aware(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text,uuid)'::regprocedure,
     $a$IF COALESCE(v_profile.role,'') NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_src.warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501'; END IF;$a$,
     $b$IF NOT public.current_user_can_access_warehouse(v_src.warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501'; END IF;$b$),
    ('public.receive_stock_transfer_quantity_at_shelf_v2(uuid,numeric,uuid,boolean,text)'::regprocedure,
     $a$IF COALESCE(v_profile.role,'') NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_t.destination_warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the destination warehouse'; END IF;$a$,
     $b$IF NOT public.current_user_can_access_warehouse(v_t.destination_warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the destination warehouse' USING ERRCODE='42501'; END IF;$b$)
  ) AS x(fn,anchor,replacement)
  LOOP
    SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid=r.fn::oid;
    v_count := (length(v_body)-length(replace(v_body,r.anchor,'')))/length(r.anchor);
    IF v_count <> 1 THEN RAISE EXCEPTION 'Expected exactly one legacy scope anchor in %, found %',r.fn,v_count; END IF;
    v_new_body := replace(v_body,r.anchor,r.replacement);
    v_def := pg_get_functiondef(r.fn::oid);
    v_new_def := replace(v_def,v_body,v_new_body);
    IF v_new_def=v_def THEN RAISE EXCEPTION 'Could not reconstruct function definition for %',r.fn; END IF;
    EXECUTE v_new_def;
  END LOOP;

  -- Internal legacy receipt/return helpers are not directly executable by authenticated,
  -- but exposed idempotent wrappers call them. Their checks must honor role scope too.
  SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid='public.confirm_stock_transfer_return(uuid)'::regprocedure;
  SELECT count(*) INTO v_count FROM regexp_matches(v_body,$rx$IF COALESCE\(v_profile\.role, ''\) NOT IN \('SUPER_ADMIN','ADMIN','MANAGER'\)\s+AND \(cardinality\(COALESCE\(v_profile\.assigned_warehouse_ids, ARRAY\[\]::uuid\[\]\)\) = 0\s+OR NOT \(v_t\.source_warehouse_id = ANY\(v_profile\.assigned_warehouse_ids\)\)\) THEN\s+RAISE EXCEPTION 'User is not assigned to the sending warehouse';\s+END IF;$rx$,'g');
  IF v_count<>1 THEN RAISE EXCEPTION 'Expected one legacy return-confirmation scope gate, found %',v_count; END IF;
  v_new_body:=regexp_replace(v_body,$rx$IF COALESCE\(v_profile\.role, ''\) NOT IN \('SUPER_ADMIN','ADMIN','MANAGER'\)\s+AND \(cardinality\(COALESCE\(v_profile\.assigned_warehouse_ids, ARRAY\[\]::uuid\[\]\)\) = 0\s+OR NOT \(v_t\.source_warehouse_id = ANY\(v_profile\.assigned_warehouse_ids\)\)\) THEN\s+RAISE EXCEPTION 'User is not assigned to the sending warehouse';\s+END IF;$rx$,$rep$IF NOT public.current_user_can_access_warehouse(v_t.source_warehouse_id) THEN
    RAISE EXCEPTION 'User is not assigned to the sending warehouse' USING ERRCODE='42501';
  END IF;$rep$);
  v_def:=pg_get_functiondef('public.confirm_stock_transfer_return(uuid)'::regprocedure);
  v_new_def:=replace(v_def,v_body,v_new_body);
  IF v_new_def=v_def THEN RAISE EXCEPTION 'Could not reconstruct confirm_stock_transfer_return'; END IF;
  EXECUTE v_new_def;

  SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid='public.receive_stock_transfer(uuid)'::regprocedure;
  SELECT count(*) INTO v_count FROM regexp_matches(v_body,$rx$IF COALESCE\(v_profile\.role, ''\) NOT IN \('SUPER_ADMIN','ADMIN','MANAGER'\)\s+AND \(\s+cardinality\(COALESCE\(v_profile\.assigned_warehouse_ids, ARRAY\[\]::uuid\[\]\)\) = 0\s+OR NOT \(v_transfer\.destination_warehouse_id = ANY\(v_profile\.assigned_warehouse_ids\)\)\s+\) THEN\s+RAISE EXCEPTION 'User is not assigned to the destination warehouse';\s+END IF;$rx$,'g');
  IF v_count<>1 THEN RAISE EXCEPTION 'Expected one legacy receive scope gate, found %',v_count; END IF;
  v_new_body:=regexp_replace(v_body,$rx$IF COALESCE\(v_profile\.role, ''\) NOT IN \('SUPER_ADMIN','ADMIN','MANAGER'\)\s+AND \(\s+cardinality\(COALESCE\(v_profile\.assigned_warehouse_ids, ARRAY\[\]::uuid\[\]\)\) = 0\s+OR NOT \(v_transfer\.destination_warehouse_id = ANY\(v_profile\.assigned_warehouse_ids\)\)\s+\) THEN\s+RAISE EXCEPTION 'User is not assigned to the destination warehouse';\s+END IF;$rx$,$rep$IF NOT public.current_user_can_access_warehouse(v_transfer.destination_warehouse_id) THEN
    RAISE EXCEPTION 'User is not assigned to the destination warehouse' USING ERRCODE='42501';
  END IF;$rep$);
  v_def:=pg_get_functiondef('public.receive_stock_transfer(uuid)'::regprocedure);
  v_new_def:=replace(v_def,v_body,v_new_body);
  IF v_new_def=v_def THEN RAISE EXCEPTION 'Could not reconstruct receive_stock_transfer'; END IF;
  EXECUTE v_new_def;
END
$scope_patch$;
DO $wrapper_scope$
DECLARE
  v_body text;
  v_new_body text;
  v_def text;
  v_new_def text;
  v_anchor text := $a$  -- The underlying routine performs permission, warehouse-scope, row-lock,
  -- stock-posting, and ledger checks. Keep both steps in this transaction.
  v_result := public.confirm_stock_transfer_return(p_transfer_id);$a$;
  v_replacement text := $b$  -- Fail closed at the exposed RPC boundary as well as in the internal posting routine.
  IF EXISTS (SELECT 1 FROM public.stock_transfers t WHERE t.id=p_transfer_id)
     AND NOT EXISTS (
       SELECT 1 FROM public.stock_transfers t
       WHERE t.id=p_transfer_id
         AND public.current_user_can_access_warehouse(t.source_warehouse_id)
     ) THEN
    RAISE EXCEPTION 'User is not assigned to the sending warehouse' USING ERRCODE='42501';
  END IF;

  -- The underlying routine performs permission, warehouse-scope, row-lock,
  -- stock-posting, and ledger checks. Keep both steps in this transaction.
  v_result := public.confirm_stock_transfer_return(p_transfer_id);$b$;
  v_count integer;
BEGIN
  SELECT p.prosrc INTO v_body FROM pg_proc p
  WHERE p.oid='public.confirm_stock_transfer_return_v2(uuid)'::regprocedure;
  v_count := (length(v_body)-length(replace(v_body,v_anchor,'')))/length(v_anchor);
  IF v_count<>1 THEN RAISE EXCEPTION 'Expected one return-confirmation wrapper anchor, found %',v_count; END IF;
  v_new_body:=replace(v_body,v_anchor,v_replacement);
  v_def:=pg_get_functiondef('public.confirm_stock_transfer_return_v2(uuid)'::regprocedure);
  v_new_def:=replace(v_def,v_body,v_new_body);
  IF v_new_def=v_def THEN RAISE EXCEPTION 'Could not reconstruct confirm_stock_transfer_return_v2'; END IF;
  EXECUTE v_new_def;
END
$wrapper_scope$;
-- RLS write policies must use the same effective scope as SECURITY DEFINER RPCs.
-- Remove privileged-role bypasses that were tied only to assigned_warehouse_ids.
ALTER POLICY stocktake_sessions_permission_insert ON public.stocktake_sessions
  WITH CHECK (
    created_by = (SELECT auth.uid())
    AND status = 'IN_PROGRESS'
    AND current_user_has_permission('action:stocktake:start')
    AND current_user_can_access_warehouse(warehouse_id)
  );
ALTER POLICY stocktake_sessions_permission_update ON public.stocktake_sessions
  USING (
    status = 'IN_PROGRESS'
    AND (created_by = (SELECT auth.uid()) OR current_user_is_manager())
    AND current_user_has_permission('action:stocktake:start')
    AND current_user_can_access_warehouse(warehouse_id)
  )
  WITH CHECK (
    status = 'IN_PROGRESS'
    AND (created_by = (SELECT auth.uid()) OR current_user_is_manager())
    AND current_user_has_permission('action:stocktake:start')
    AND current_user_can_access_warehouse(warehouse_id)
  );
ALTER POLICY stocktake_sessions_permission_delete ON public.stocktake_sessions
  USING (
    status = 'IN_PROGRESS'
    AND current_user_is_manager()
    AND current_user_can_access_warehouse(warehouse_id)
  );

ALTER POLICY transactions_permission_insert ON public.transactions
  WITH CHECK (
    created_by = (SELECT auth.uid())
    AND status = 'PENDING_APPROVAL'
    AND CASE transaction_type
      WHEN 'GRN' THEN current_user_has_permission('action:transaction:grn:create')
      WHEN 'RETURN_FROM_USAGE' THEN current_user_has_permission('action:transaction:grn:create')
      WHEN 'RETURN_FROM_CUSTOMER' THEN current_user_has_permission('action:transaction:grn:create')
      WHEN 'ISSUE' THEN current_user_has_permission('action:transaction:issue:create')
      WHEN 'RETURN_TO_SUPPLIER' THEN current_user_has_permission('action:transaction:issue:create')
      WHEN 'ADJUSTMENT_IN' THEN current_user_has_permission('action:transaction:adjustment:create')
      WHEN 'ADJUSTMENT_OUT' THEN current_user_has_permission('action:transaction:adjustment:create')
      WHEN 'OPENING_BALANCE' THEN current_user_is_manager()
      ELSE false
    END
    AND current_user_can_access_warehouse(warehouse_id)
  );
ALTER POLICY transactions_permission_update ON public.transactions
  USING (
    status = 'PENDING_APPROVAL'
    AND (created_by = (SELECT auth.uid()) OR current_user_is_manager())
    AND current_user_can_access_warehouse(warehouse_id)
  )
  WITH CHECK (
    status = 'PENDING_APPROVAL'
    AND (created_by = (SELECT auth.uid()) OR current_user_is_manager())
    AND current_user_can_access_warehouse(warehouse_id)
  );
ALTER POLICY transactions_permission_delete ON public.transactions
  USING (
    status = 'PENDING_APPROVAL'
    AND (created_by = (SELECT auth.uid()) OR current_user_is_manager())
    AND current_user_can_access_warehouse(warehouse_id)
  );

ALTER POLICY transaction_lines_permission_insert ON public.transaction_lines
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.transactions t
      WHERE t.id = transaction_lines.transaction_id
        AND t.status = 'PENDING_APPROVAL'
        AND (t.created_by = (SELECT auth.uid()) OR current_user_is_manager())
        AND current_user_can_access_warehouse(t.warehouse_id)
    )
  );
ALTER POLICY transaction_lines_permission_update ON public.transaction_lines
  USING (
    EXISTS (
      SELECT 1 FROM public.transactions t
      WHERE t.id = transaction_lines.transaction_id
        AND t.status = 'PENDING_APPROVAL'
        AND (t.created_by = (SELECT auth.uid()) OR current_user_is_manager())
        AND current_user_can_access_warehouse(t.warehouse_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.transactions t
      WHERE t.id = transaction_lines.transaction_id
        AND t.status = 'PENDING_APPROVAL'
        AND (t.created_by = (SELECT auth.uid()) OR current_user_is_manager())
        AND current_user_can_access_warehouse(t.warehouse_id)
    )
  );
ALTER POLICY transaction_lines_permission_delete ON public.transaction_lines
  USING (
    EXISTS (
      SELECT 1 FROM public.transactions t
      WHERE t.id = transaction_lines.transaction_id
        AND t.status = 'PENDING_APPROVAL'
        AND (t.created_by = (SELECT auth.uid()) OR current_user_is_manager())
        AND current_user_can_access_warehouse(t.warehouse_id)
    )
  );

ALTER POLICY stocktake_lines_permission_insert ON public.stocktake_lines
  WITH CHECK (
    current_user_has_permission('action:stocktake:start')
    AND EXISTS (
      SELECT 1 FROM public.stocktake_sessions s
      WHERE s.id = stocktake_lines.session_id
        AND s.status = 'IN_PROGRESS'
        AND (s.created_by = (SELECT auth.uid()) OR current_user_is_manager())
        AND current_user_can_access_warehouse(s.warehouse_id)
    )
  );
ALTER POLICY stocktake_lines_permission_update ON public.stocktake_lines
  USING (
    current_user_has_permission('action:stocktake:start')
    AND COALESCE(is_settled, false) = false
    AND EXISTS (
      SELECT 1 FROM public.stocktake_sessions s
      WHERE s.id = stocktake_lines.session_id
        AND s.status = 'IN_PROGRESS'
        AND (s.created_by = (SELECT auth.uid()) OR current_user_is_manager())
        AND current_user_can_access_warehouse(s.warehouse_id)
    )
  )
  WITH CHECK (
    current_user_has_permission('action:stocktake:start')
    AND COALESCE(is_settled, false) = false
    AND EXISTS (
      SELECT 1 FROM public.stocktake_sessions s
      WHERE s.id = stocktake_lines.session_id
        AND s.status = 'IN_PROGRESS'
        AND (s.created_by = (SELECT auth.uid()) OR current_user_is_manager())
        AND current_user_can_access_warehouse(s.warehouse_id)
    )
  );
ALTER POLICY stocktake_lines_permission_delete ON public.stocktake_lines
  USING (
    current_user_has_permission('action:stocktake:start')
    AND COALESCE(is_settled, false) = false
    AND EXISTS (
      SELECT 1 FROM public.stocktake_sessions s
      WHERE s.id = stocktake_lines.session_id
        AND s.status = 'IN_PROGRESS'
        AND (s.created_by = (SELECT auth.uid()) OR current_user_is_manager())
        AND current_user_can_access_warehouse(s.warehouse_id)
    )
  );

COMMIT;
