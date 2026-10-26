-- ORSHAP WMS v13.9.58: enforce assigned-warehouse scope in database reads and writes.
-- Review-only migration: do not apply directly to the live project before PR validation.
BEGIN;
CREATE OR REPLACE FUNCTION public.current_user_can_access_warehouse(p_warehouse_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT CASE WHEN auth.uid() IS NULL OR p_warehouse_id IS NULL THEN false
  ELSE EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id=(SELECT auth.uid()) AND p.status='ACTIVE'
      AND (p_warehouse_id=ANY(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[]))
        OR (cardinality(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[]))=0
            AND p.role IN ('SUPER_ADMIN','ADMIN')))
  ) END;
$$;

-- Private server-side context for narrowly permitted cross-warehouse transfer lifecycle writes.
-- Authenticated clients can set arbitrary custom GUC values, so a GUC alone is not an authorization proof.
CREATE TABLE IF NOT EXISTS public.wms_transfer_scope_context (
  transaction_id bigint PRIMARY KEY,
  transfer_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  context_type text NOT NULL CHECK (context_type IN ('REJECT_RECEIPT','FINALIZE_SOURCE')),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.wms_transfer_scope_context ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.wms_transfer_scope_context FROM PUBLIC, anon, authenticated;

-- Transfer lifecycle exception: a destination-assigned user may reject receipt and return stock to source,
-- and may finalize the source issue after received+returned quantities reconcile. The only cross-scope
-- context is set inside the validated SECURITY DEFINER RPCs below; triggers verify the exact transfer,
-- endpoint assignment, reference/status, and quantity reconciliation before allowing that one write.
CREATE OR REPLACE FUNCTION public.enforce_transaction_warehouse_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $
DECLARE v_transfer_id uuid; v_context_type text; v_transfer_exception boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  SELECT c.transfer_id,c.context_type INTO v_transfer_id,v_context_type
    FROM public.wms_transfer_scope_context c
    WHERE c.transaction_id=txid_current() AND c.actor_id=auth.uid();
  IF v_transfer_id IS NOT NULL THEN
    IF TG_OP='INSERT' AND v_context_type='REJECT_RECEIPT' AND NEW.transaction_type='ADJUSTMENT_IN' AND NEW.status='APPROVED'
       AND EXISTS (SELECT 1 FROM public.stock_transfers st
         WHERE st.id=v_transfer_id AND NEW.reference_no=st.reference_no||'-REJECT-RETURN'
           AND NEW.warehouse_id=st.source_warehouse_id AND st.status='IN_TRANSIT'
           AND st.rejection_transaction_id IS NULL
           AND public.current_user_can_access_warehouse(st.destination_warehouse_id)) THEN
      v_transfer_exception := true;
    ELSIF TG_OP='UPDATE' AND v_context_type='FINALIZE_SOURCE' AND OLD.status='PENDING_RECEIPT' AND NEW.status='APPROVED'
       AND EXISTS (SELECT 1 FROM public.stock_transfers st
         WHERE st.id=v_transfer_id AND st.source_transaction_id=OLD.id
           AND NEW.warehouse_id=st.source_warehouse_id
           AND COALESCE(st.received_quantity,0)+COALESCE(st.returned_quantity,0)>=st.quantity
           AND (public.current_user_can_access_warehouse(st.source_warehouse_id)
                OR public.current_user_can_access_warehouse(st.destination_warehouse_id))) THEN
      v_transfer_exception := true;
    END IF;
  END IF;
  IF TG_OP <> 'INSERT' AND NOT public.current_user_can_access_warehouse(OLD.warehouse_id) AND NOT v_transfer_exception THEN
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED: transaction is outside the current user assigned warehouses' USING ERRCODE='42501';
  END IF;
  IF NOT public.current_user_can_access_warehouse(NEW.warehouse_id) AND NOT v_transfer_exception THEN
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED: transaction warehouse is not assigned to the current user' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END;
$;
DROP TRIGGER IF EXISTS trg_enforce_transaction_warehouse_scope ON public.transactions;
CREATE TRIGGER trg_enforce_transaction_warehouse_scope BEFORE INSERT OR UPDATE ON public.transactions
FOR EACH ROW EXECUTE FUNCTION public.enforce_transaction_warehouse_scope();

CREATE OR REPLACE FUNCTION public.enforce_transaction_line_warehouse_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $
DECLARE v_tx_id uuid; v_warehouse_id uuid; v_transfer_id uuid; v_context_type text;
BEGIN
  IF auth.uid() IS NULL THEN IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW; END IF;
  v_tx_id := CASE WHEN TG_OP='DELETE' THEN OLD.transaction_id ELSE NEW.transaction_id END;
  SELECT t.warehouse_id INTO v_warehouse_id FROM public.transactions t WHERE t.id=v_tx_id;
  IF v_warehouse_id IS NULL AND TG_OP='DELETE' THEN RETURN OLD; END IF;
  IF v_warehouse_id IS NULL OR NOT public.current_user_can_access_warehouse(v_warehouse_id) THEN
    SELECT c.transfer_id,c.context_type INTO v_transfer_id,v_context_type
      FROM public.wms_transfer_scope_context c
      WHERE c.transaction_id=txid_current() AND c.actor_id=auth.uid();
    IF TG_OP='INSERT' AND v_context_type='REJECT_RECEIPT' AND v_transfer_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.transactions t JOIN public.stock_transfers st ON st.id=v_transfer_id
      WHERE t.id=v_tx_id AND t.transaction_type='ADJUSTMENT_IN' AND t.status='APPROVED'
        AND t.reference_no=st.reference_no||'-REJECT-RETURN' AND t.warehouse_id=st.source_warehouse_id
        AND st.status='IN_TRANSIT' AND st.rejection_transaction_id IS NULL
        AND public.current_user_can_access_warehouse(st.destination_warehouse_id)
    ) THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED: transaction line is outside the current user assigned warehouses' USING ERRCODE='42501';
  END IF;
  IF TG_OP='UPDATE' AND OLD.transaction_id IS DISTINCT FROM NEW.transaction_id THEN
    RAISE EXCEPTION 'Transaction lines cannot be moved between transactions';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END;
$;
DROP TRIGGER IF EXISTS trg_enforce_transaction_line_warehouse_scope ON public.transaction_lines;
CREATE TRIGGER trg_enforce_transaction_line_warehouse_scope BEFORE INSERT OR UPDATE OR DELETE ON public.transaction_lines
FOR EACH ROW EXECUTE FUNCTION public.enforce_transaction_line_warehouse_scope();

CREATE OR REPLACE FUNCTION public.enforce_stocktake_warehouse_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF TG_OP <> 'INSERT' AND NOT public.current_user_can_access_warehouse(OLD.warehouse_id) THEN
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED: stocktake session is outside the current user assigned warehouses' USING ERRCODE='42501';
  END IF;
  IF NOT public.current_user_can_access_warehouse(NEW.warehouse_id) THEN
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED: stocktake warehouse is not assigned to the current user' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_enforce_stocktake_warehouse_scope ON public.stocktake_sessions;
CREATE TRIGGER trg_enforce_stocktake_warehouse_scope BEFORE INSERT OR UPDATE ON public.stocktake_sessions
FOR EACH ROW EXECUTE FUNCTION public.enforce_stocktake_warehouse_scope();

CREATE OR REPLACE FUNCTION public.enforce_stocktake_line_warehouse_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_session_id uuid; v_warehouse_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW; END IF;
  v_session_id := CASE WHEN TG_OP='DELETE' THEN OLD.session_id ELSE NEW.session_id END;
  SELECT s.warehouse_id INTO v_warehouse_id FROM public.stocktake_sessions s WHERE s.id=v_session_id;
  -- Permit only a cascading delete whose parent session is already being removed.
  IF v_warehouse_id IS NULL AND TG_OP='DELETE' THEN RETURN OLD; END IF;
  IF v_warehouse_id IS NULL OR NOT public.current_user_can_access_warehouse(v_warehouse_id) THEN
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED: stocktake line is outside the current user assigned warehouses' USING ERRCODE='42501';
  END IF;
  IF TG_OP='UPDATE' AND OLD.session_id IS DISTINCT FROM NEW.session_id THEN
    RAISE EXCEPTION 'Stocktake lines cannot be moved between sessions';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_enforce_stocktake_line_warehouse_scope ON public.stocktake_lines;
CREATE TRIGGER trg_enforce_stocktake_line_warehouse_scope BEFORE INSERT OR UPDATE OR DELETE ON public.stocktake_lines
FOR EACH ROW EXECUTE FUNCTION public.enforce_stocktake_line_warehouse_scope();

CREATE OR REPLACE FUNCTION public.current_user_can_create_warehouse()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $create_warehouse$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id=(SELECT auth.uid()) AND p.status='ACTIVE'
      AND p.role IN ('SUPER_ADMIN','ADMIN')
      AND cardinality(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[]))=0
      AND public.current_user_has_permission('action:warehouse:manage')
  );
$create_warehouse$;

DROP POLICY IF EXISTS warehouses_active_read ON public.warehouses;
CREATE POLICY warehouses_active_read ON public.warehouses FOR SELECT
USING (public.current_user_is_active() AND public.current_user_can_access_warehouse(id));
DROP POLICY IF EXISTS warehouses_manager_insert ON public.warehouses;
CREATE POLICY warehouses_manager_insert ON public.warehouses FOR INSERT
WITH CHECK (public.current_user_can_create_warehouse());
DROP POLICY IF EXISTS warehouses_manager_update ON public.warehouses;
CREATE POLICY warehouses_manager_update ON public.warehouses FOR UPDATE
USING (public.current_user_has_permission('action:warehouse:manage') AND public.current_user_can_access_warehouse(id))
WITH CHECK (public.current_user_has_permission('action:warehouse:manage') AND public.current_user_can_access_warehouse(id));
DROP POLICY IF EXISTS warehouses_manager_delete ON public.warehouses;
CREATE POLICY warehouses_manager_delete ON public.warehouses FOR DELETE
USING (public.current_user_has_permission('action:warehouse:manage') AND public.current_user_can_access_warehouse(id));
DROP POLICY IF EXISTS storage_areas_active_read ON public.storage_areas;
CREATE POLICY storage_areas_active_read ON public.storage_areas FOR SELECT
USING (public.current_user_is_active() AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS storage_areas_manager_insert ON public.storage_areas;
CREATE POLICY storage_areas_manager_insert ON public.storage_areas FOR INSERT
WITH CHECK (public.current_user_has_permission('action:facility:manage') AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS storage_areas_manager_update ON public.storage_areas;
CREATE POLICY storage_areas_manager_update ON public.storage_areas FOR UPDATE
USING (public.current_user_has_permission('action:facility:manage') AND public.current_user_can_access_warehouse(warehouse_id))
WITH CHECK (public.current_user_has_permission('action:facility:manage') AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS storage_areas_manager_delete ON public.storage_areas;
CREATE POLICY storage_areas_manager_delete ON public.storage_areas FOR DELETE
USING (public.current_user_has_permission('action:facility:manage') AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS shelves_active_read ON public.shelves;
CREATE POLICY shelves_active_read ON public.shelves FOR SELECT
USING (public.current_user_is_active() AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS shelves_manager_insert ON public.shelves;
CREATE POLICY shelves_manager_insert ON public.shelves FOR INSERT
WITH CHECK (public.current_user_has_permission('action:facility:manage') AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS shelves_manager_update ON public.shelves;
CREATE POLICY shelves_manager_update ON public.shelves FOR UPDATE
USING (public.current_user_has_permission('action:facility:manage') AND public.current_user_can_access_warehouse(warehouse_id))
WITH CHECK (public.current_user_has_permission('action:facility:manage') AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS shelves_manager_delete ON public.shelves;
CREATE POLICY shelves_manager_delete ON public.shelves FOR DELETE
USING (public.current_user_has_permission('action:facility:manage') AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS stock_authenticated_read ON public.stock;
CREATE POLICY stock_authenticated_read ON public.stock FOR SELECT
USING (public.current_user_has_permission('table:inventory:view') AND EXISTS (
  SELECT 1 FROM public.shelves sh WHERE sh.id=stock.shelf_id AND public.current_user_can_access_warehouse(sh.warehouse_id)
));
DROP POLICY IF EXISTS transactions_permission_select ON public.transactions;
CREATE POLICY transactions_permission_select ON public.transactions FOR SELECT
USING (current_user_has_permission('table:transactions:view')
  AND public.current_user_can_access_warehouse(warehouse_id)
  AND (created_by=(SELECT auth.uid()) OR current_user_has_permission('action:transaction:view_others')));
DROP POLICY IF EXISTS transaction_lines_permission_select ON public.transaction_lines;
CREATE POLICY transaction_lines_permission_select ON public.transaction_lines FOR SELECT
USING (current_user_has_permission('table:transactions:view') AND EXISTS (
  SELECT 1 FROM public.transactions t WHERE t.id=transaction_lines.transaction_id
  AND public.current_user_can_access_warehouse(t.warehouse_id)
  AND (t.created_by=(SELECT auth.uid()) OR current_user_has_permission('action:transaction:view_others'))
));
DROP POLICY IF EXISTS inventory_ledger_select_policy ON public.inventory_ledger;
CREATE POLICY inventory_ledger_select_policy ON public.inventory_ledger FOR SELECT
USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id=(SELECT auth.uid()) AND p.status='ACTIVE'
  AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER','WAREHOUSE_MANAGER')
       OR COALESCE(p.custom_permissions,ARRAY[]::text[]) @> ARRAY['VIEW_LEDGER']::text[]))
  AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS transaction_ledger_authenticated_read ON public.transaction_ledger;
CREATE POLICY transaction_ledger_authenticated_read ON public.transaction_ledger FOR SELECT
USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id=(SELECT auth.uid()) AND p.status='ACTIVE'
  AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER','WAREHOUSE_MANAGER')
       OR COALESCE(p.custom_permissions,ARRAY[]::text[]) @> ARRAY['VIEW_LEDGER']::text[]
       OR COALESCE(p.custom_permissions,ARRAY[]::text[]) @> ARRAY['VIEW_AUDIT']::text[]))
  AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS stocktake_sessions_permission_select ON public.stocktake_sessions;
CREATE POLICY stocktake_sessions_permission_select ON public.stocktake_sessions FOR SELECT
USING ((current_user_has_permission('page:stocktake:access') OR current_user_has_permission('table:stocktake:view'))
  AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS stocktake_lines_permission_select ON public.stocktake_lines;
CREATE POLICY stocktake_lines_permission_select ON public.stocktake_lines FOR SELECT
USING ((current_user_has_permission('page:stocktake:access') OR current_user_has_permission('table:stocktake:view'))
  AND EXISTS (SELECT 1 FROM public.stocktake_sessions s WHERE s.id=stocktake_lines.session_id
              AND public.current_user_can_access_warehouse(s.warehouse_id)));
DROP POLICY IF EXISTS stocktake_logs_permission_select ON public.stocktake_logs;
CREATE POLICY stocktake_logs_permission_select ON public.stocktake_logs FOR SELECT
USING ((current_user_has_permission('page:stocktake:access') OR current_user_has_permission('table:stocktake:view'))
  AND EXISTS (SELECT 1 FROM public.stocktake_sessions s WHERE s.id=stocktake_logs.session_id
              AND public.current_user_can_access_warehouse(s.warehouse_id)));
-- Scope archive mutations to the same warehouse assignment as archive reads.
DROP POLICY IF EXISTS archive_movements_manager_insert ON public.archive_movements;
CREATE POLICY archive_movements_manager_insert ON public.archive_movements FOR INSERT
WITH CHECK (public.current_user_is_manager() AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS archive_movements_manager_update ON public.archive_movements;
CREATE POLICY archive_movements_manager_update ON public.archive_movements FOR UPDATE
USING (public.current_user_is_manager() AND public.current_user_can_access_warehouse(warehouse_id))
WITH CHECK (public.current_user_is_manager() AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS archive_movements_manager_delete ON public.archive_movements;
CREATE POLICY archive_movements_manager_delete ON public.archive_movements FOR DELETE
USING (public.current_user_is_manager() AND public.current_user_can_access_warehouse(warehouse_id));

DROP POLICY IF EXISTS archive_balances_manager_insert ON public.archive_balances;
CREATE POLICY archive_balances_manager_insert ON public.archive_balances FOR INSERT
WITH CHECK (public.current_user_is_manager() AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS archive_balances_manager_update ON public.archive_balances;
CREATE POLICY archive_balances_manager_update ON public.archive_balances FOR UPDATE
USING (public.current_user_is_manager() AND public.current_user_can_access_warehouse(warehouse_id))
WITH CHECK (public.current_user_is_manager() AND public.current_user_can_access_warehouse(warehouse_id));
DROP POLICY IF EXISTS archive_balances_manager_delete ON public.archive_balances;
CREATE POLICY archive_balances_manager_delete ON public.archive_balances FOR DELETE
USING (public.current_user_is_manager() AND public.current_user_can_access_warehouse(warehouse_id));

-- Scope archive, audit, and transfer reads too; these tables can expose transaction history.
DROP POLICY IF EXISTS archive_movements_active_read ON public.archive_movements;
CREATE POLICY archive_movements_active_read ON public.archive_movements FOR SELECT
USING (public.current_user_is_active() AND public.current_user_can_access_warehouse(warehouse_id));

DROP POLICY IF EXISTS archive_balances_active_read ON public.archive_balances;
CREATE POLICY archive_balances_active_read ON public.archive_balances FOR SELECT
USING (public.current_user_is_active() AND public.current_user_can_access_warehouse(warehouse_id));

DROP POLICY IF EXISTS transaction_audit_select_policy ON public.transaction_audit;
CREATE POLICY transaction_audit_select_policy ON public.transaction_audit FOR SELECT
USING (
  EXISTS (SELECT 1 FROM public.profiles p
          WHERE p.id=(SELECT auth.uid()) AND p.status='ACTIVE'
            AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
                 OR COALESCE(p.custom_permissions,ARRAY[]::text[]) @> ARRAY['VIEW_AUDIT']::text[]))
  AND EXISTS (SELECT 1 FROM public.transactions t
              WHERE t.id=transaction_audit.transaction_id
                AND public.current_user_can_access_warehouse(t.warehouse_id))
);

DROP POLICY IF EXISTS audit_logs_select_policy ON public.audit_logs;
CREATE POLICY audit_logs_select_policy ON public.audit_logs FOR SELECT
USING (
  EXISTS (SELECT 1 FROM public.profiles p
          WHERE p.id=(SELECT auth.uid()) AND p.status='ACTIVE'
            AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
                 OR COALESCE(p.custom_permissions,ARRAY[]::text[]) @> ARRAY['VIEW_AUDIT']::text[]))
  AND (
    (warehouse_id IS NOT NULL AND public.current_user_can_access_warehouse(warehouse_id))
    OR (warehouse_id IS NULL AND entity='TRANSACTION'
        AND EXISTS (SELECT 1 FROM public.transactions t
                    WHERE t.id::text=audit_logs.entity_id
                      AND public.current_user_can_access_warehouse(t.warehouse_id)))
    OR (warehouse_id IS NULL AND entity IS DISTINCT FROM 'TRANSACTION'
        AND COALESCE(details,'') !~* '"(warehouse_id|warehouseId|tx_id|transaction_id)"[[:space:]]*:')
  )
);

DROP POLICY IF EXISTS stock_transfers_select_assigned ON public.stock_transfers;
CREATE POLICY stock_transfers_select_assigned ON public.stock_transfers FOR SELECT
USING (
  (current_user_has_permission('action:stock_transfer:view')
   OR current_user_has_permission('action:stock_transfer:receive')
   OR current_user_has_permission('action:stock_transfer:create'))
  AND (public.current_user_can_access_warehouse(source_warehouse_id)
       OR public.current_user_can_access_warehouse(destination_warehouse_id))
);

DROP POLICY IF EXISTS stock_transfer_orders_select_assigned ON public.stock_transfer_orders;
CREATE POLICY stock_transfer_orders_select_assigned ON public.stock_transfer_orders FOR SELECT
USING (
  (current_user_has_permission('action:stock_transfer:view')
   OR current_user_has_permission('action:stock_transfer:receive')
   OR current_user_has_permission('action:stock_transfer:create'))
  AND (public.current_user_can_access_warehouse(source_warehouse_id)
       OR public.current_user_can_access_warehouse(destination_warehouse_id))
);

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
 IF NOT public.current_user_can_access_warehouse(v_transfer.destination_warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the destination warehouse' USING ERRCODE='42501'; END IF;
 SELECT * INTO v_shelf FROM public.shelves WHERE id=v_transfer.source_shelf_id AND warehouse_id=v_transfer.source_warehouse_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Source shelf is no longer valid for the source warehouse'; END IF;
 v_area:=v_shelf.storage_area_id;
 v_lock_key:=v_transfer.item_id::text||':'||v_transfer.source_shelf_id::text||':'||v_transfer.batch_no||':'||v_owner::text;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_lock_key,0));
 SELECT quantity INTO v_before FROM public.stock WHERE item_id=v_transfer.item_id AND shelf_id=v_transfer.source_shelf_id AND batch_no=v_transfer.batch_no AND storage_area_id=v_area AND administrative_department_id=v_owner FOR UPDATE;
 v_before:=COALESCE(v_before,0); v_after:=v_before+v_transfer.quantity; v_tx:=gen_random_uuid();
 INSERT INTO public.wms_transfer_scope_context(transaction_id,transfer_id,actor_id,context_type) VALUES(txid_current(),p_transfer_id,v_user,'REJECT_RECEIPT');
 INSERT INTO public.transactions(id,reference_no,transaction_type,status,warehouse_id,storage_area_id,notes,created_by)
 VALUES(v_tx,v_transfer.reference_no||'-REJECT-RETURN','ADJUSTMENT_IN','APPROVED',v_shelf.warehouse_id,v_area,'Rejected transfer receipt; goods returned to source. Reason: '||btrim(p_reason),v_user);
 INSERT INTO public.transaction_lines(transaction_id,item_id,shelf_id,administrative_department_id,quantity,balance_before,balance_after,batch_no,expiry_date,storage_area_id,notes)
 VALUES(v_tx,v_transfer.item_id,v_transfer.source_shelf_id,v_owner,v_transfer.quantity,v_before,v_after,v_transfer.batch_no,v_transfer.expiry_date,v_area,'Transfer='||p_transfer_id::text||'; direction=REJECTED_RETURN; reason='||btrim(p_reason));
 DELETE FROM public.wms_transfer_scope_context WHERE transaction_id=txid_current() AND transfer_id=p_transfer_id AND actor_id=v_user AND context_type='REJECT_RECEIPT';
 INSERT INTO public.stock(item_id,shelf_id,administrative_department_id,quantity,batch_no,expiry_date,storage_area_id,updated_at)
 VALUES(v_transfer.item_id,v_transfer.source_shelf_id,v_owner,v_after,v_transfer.batch_no,v_transfer.expiry_date,v_area,now())
 ON CONFLICT (item_id, shelf_id, batch_no, administrative_department_id) DO UPDATE SET quantity=EXCLUDED.quantity,expiry_date=COALESCE(EXCLUDED.expiry_date,public.stock.expiry_date),storage_area_id=COALESCE(EXCLUDED.storage_area_id,public.stock.storage_area_id),updated_at=now();
 PERFORM public.log_transaction_ledger(p_transaction_id:=v_tx,p_ledger_type:='STOCK_TRANSFER',p_user_id:=v_user,p_warehouse_id:=v_shelf.warehouse_id,p_zone_id:=NULL::uuid,p_section_id:=NULL::uuid,p_shelf_id:=v_transfer.source_shelf_id,p_item_id:=v_transfer.item_id,p_quantity:=v_transfer.quantity,p_balance_before:=v_before,p_balance_after:=v_after,p_transaction_type:='ADJUSTMENT_IN',p_details:=jsonb_build_object('transfer_id',p_transfer_id,'rejected_at_destination',v_transfer.destination_warehouse_id,'reason',btrim(p_reason),'batch_no',v_transfer.batch_no,'administrative_department_id',v_owner,'storage_area_id',v_area),p_reference:=v_transfer.reference_no,p_approved:=true,p_reference_type:='STOCK_TRANSFER_REJECTED_RETURN',p_batch_no:=v_transfer.batch_no,p_expiry_date:=v_transfer.expiry_date);
 UPDATE public.stock_transfers SET status='REJECTED',rejected_by=v_user,rejected_at=now(),rejection_reason=btrim(p_reason),rejection_transaction_id=v_tx,notes=concat_ws(E'\n',NULLIF(notes,''),'REJECTED: '||btrim(p_reason)),updated_at=now() WHERE id=p_transfer_id;
 INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,reference,details)
 VALUES(v_user,'STOCK_TRANSFER_RECEIPT_REJECTED','STOCK_TRANSFER',p_transfer_id::text,v_shelf.warehouse_id,v_transfer.reference_no,jsonb_build_object('reason',btrim(p_reason),'quantity_returned_to_source',v_transfer.quantity,'source_balance_after',v_after,'destination_warehouse_id',v_transfer.destination_warehouse_id,'administrative_department_id',v_owner));
 RETURN jsonb_build_object('success',true,'already_rejected',false,'transfer_id',p_transfer_id,'status','REJECTED','destination_transaction_id',v_tx,'source_balance_after',v_after);
END;$function$
;

CREATE OR REPLACE FUNCTION public.finalize_stock_transfer_source_issue(p_transfer_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
                             DECLARE
                               v_t public.stock_transfers%ROWTYPE;
                                 v_tx_status text;
                                   v_line record;
                               v_updated boolean;
                                   BEGIN
                                     IF p_transfer_id IS NULL OR p_user_id IS NULL THEN
                                         RAISE EXCEPTION 'Transfer ID and acting user are required';
                                           END IF;
                                             SELECT * INTO v_t FROM public.stock_transfers WHERE id=p_transfer_id FOR UPDATE;
                                               IF NOT FOUND THEN RAISE EXCEPTION 'Stock transfer line not found'; END IF;
                                                 IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_user_id OR NOT public.current_user_is_active()
                                                    OR NOT (public.current_user_can_access_warehouse(v_t.source_warehouse_id) OR public.current_user_can_access_warehouse(v_t.destination_warehouse_id)) THEN
                                                   RAISE EXCEPTION 'User is not assigned to either transfer warehouse' USING ERRCODE='42501';
                                                 END IF;

                                                 IF COALESCE(v_t.received_quantity,0)+COALESCE(v_t.returned_quantity,0) < v_t.quantity THEN
                                                     RETURN false;
                                                       END IF;
                                                         IF v_t.source_transaction_id IS NULL THEN
                                                             RAISE EXCEPTION 'Source issue transaction is missing for transfer %',p_transfer_id;
                                                               END IF;

                                                                 INSERT INTO public.wms_transfer_scope_context(transaction_id,transfer_id,actor_id,context_type) VALUES(txid_current(),p_transfer_id,auth.uid(),'FINALIZE_SOURCE');
                                                                 UPDATE public.transactions
                                                                      SET status='APPROVED'
                                                                         WHERE id=v_t.source_transaction_id AND status='PENDING_RECEIPT';
                                                                 v_updated := FOUND;
                                                                 DELETE FROM public.wms_transfer_scope_context WHERE transaction_id=txid_current() AND transfer_id=p_transfer_id AND actor_id=auth.uid() AND context_type='FINALIZE_SOURCE';

                                                                           IF v_updated THEN
                                                                               UPDATE public.transaction_ledger
                                                                                      SET approved=true, approved_at=now(), administrative_department_id=v_t.administrative_department_id
                                                                                           WHERE transaction_id=v_t.source_transaction_id AND approved IS DISTINCT FROM true;

                                                                                               FOR v_line IN
                                                                                                     SELECT t.id AS transaction_id,t.reference_no,t.warehouse_id,NULL::uuid AS zone_id,NULL::uuid AS section_id,t.storage_area_id,
                                                                                                                  t.created_by,t.created_at,tl.item_id,tl.shelf_id,tl.quantity,tl.balance_after,tl.batch_no,
                                                                                                                               tl.expiry_date,tl.storage_area_id AS line_storage_area_id,tl.administrative_department_id,tl.notes,
                                                                                                                                            i.code AS item_code,i.name_en AS item_name,i.base_unit
                                                                                                                                                    FROM public.transactions t
                                                                                                                                                            JOIN public.transaction_lines tl ON tl.transaction_id=t.id
                                                                                                                                                                    JOIN public.items i ON i.id=tl.item_id
                                                                                                                                                                           WHERE t.id=v_t.source_transaction_id
                                                                                                                                                                               LOOP
                                                                                                                                                                                     -- Keep the ledger event's effective time at dispatch time. The row is approved now, but
                                                                                                                                                                                           -- stock was physically deducted when the transfer was dispatched; later movements' stored
                                                                                                                                                                                                 -- running balances therefore remain chronologically consistent.
                                                                                                                                                                                                       INSERT INTO public.inventory_ledger(
                                                                                                                                                                                                               occurred_at,item_id,item_code,item_name,warehouse_id,shelf_id,
                                                                                                                                                                                                                       delta,unit,source_type,source_id,source_ref,running_balance,created_by,notes,metadata,
                                                                                                                                                                                                                               batch_no,expiry_date,storage_area_id,administrative_department_id
                                                                                                                                                                                                                                     ) VALUES (
                                                                                                                                                                                                                                             v_line.created_at,v_line.item_id,COALESCE(v_line.item_code,''),COALESCE(v_line.item_name,''),
                                                                                                                                                                                                                                                     v_line.warehouse_id,v_line.shelf_id,-v_line.quantity,
                                                                                                                                                                                                                                                             COALESCE(v_line.base_unit,'PCS'),'TRANSFER_OUT',v_line.transaction_id,v_line.reference_no,
                                                                                                                                                                                                                                                                     v_line.balance_after,v_line.created_by,
                                                                                                                                                                                                                                                                             'Transfer issue finalized after all quantities were received or physically returned. '||COALESCE(v_line.notes,''),
                                                                                                                                                                                                                                                                                     jsonb_build_object('transfer_id',p_transfer_id,'finalized_after_receipt_or_return',true,
                                                                                                                                                                                                                                                                                               'finalized_by',p_user_id,'batch_no',v_line.batch_no,'expiry_date',v_line.expiry_date),
                                                                                                                                                                                                                                                                                                       v_line.batch_no,v_line.expiry_date,COALESCE(v_line.line_storage_area_id,v_line.storage_area_id),v_line.administrative_department_id
                                                                                                                                                                                                                                                                                                             );
                                                                                                                                                                                                                                                                                                                 END LOOP;

                                                                                                                                                                                                                                                                                                                     INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,reference,details)
                                                                                                                                                                                                                                                                                                                         VALUES(p_user_id,'STOCK_TRANSFER_SOURCE_ISSUE_FINALIZED','STOCK_TRANSFER',p_transfer_id::text,
                                                                                                                                                                                                                                                                                                                                    v_t.source_warehouse_id,v_t.reference_no,
                                                                                                                                                                                                                                                                                                                                               jsonb_build_object('source_transaction_id',v_t.source_transaction_id,
                                                                                                                                                                                                                                                                                                                                                            'dispatched_quantity',v_t.quantity,'received_quantity',COALESCE(v_t.received_quantity,0),
                                                                                                                                                                                                                                                                                                                                                                         'returned_quantity',COALESCE(v_t.returned_quantity,0),'status',v_t.status)::text);
                                                                                                                                                                                                                                                                                                                                                                             RETURN true;
                                                                                                                                                                                                                                                                                                                                                                               END IF;

                                                                                                                                                                                                                                                                                                                                                                                 SELECT status INTO v_tx_status FROM public.transactions WHERE id=v_t.source_transaction_id;
                                                                                                                                                                                                                                                                                                                                                                                   IF v_tx_status='APPROVED' THEN RETURN true; END IF;
                                                                                                                                                                                                                                                                                                                                                                                     RAISE EXCEPTION 'Source issue cannot be finalized from status %',COALESCE(v_tx_status,'<missing>');
                                                                                                                                                                                                                                                                                                                                                                                     END;
                                                                                                                                                                                                                                                                                                                                                                                     $function$
;

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
 IF NOT public.current_user_can_access_warehouse(v_transfer.destination_warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the destination warehouse' USING ERRCODE='42501'; END IF;
 SELECT * INTO v_shelf FROM public.shelves WHERE id=v_transfer.source_shelf_id AND warehouse_id=v_transfer.source_warehouse_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Source shelf is no longer valid for the source warehouse'; END IF;
 v_area:=v_shelf.storage_area_id;
 v_lock_key:=v_transfer.item_id::text||':'||v_transfer.source_shelf_id::text||':'||v_transfer.batch_no||':'||v_owner::text;
 PERFORM pg_advisory_xact_lock(hashtextextended(v_lock_key,0));
 SELECT quantity INTO v_before FROM public.stock WHERE item_id=v_transfer.item_id AND shelf_id=v_transfer.source_shelf_id AND batch_no=v_transfer.batch_no AND storage_area_id=v_area AND administrative_department_id=v_owner FOR UPDATE;
 v_before:=COALESCE(v_before,0); v_after:=v_before+v_transfer.quantity; v_tx:=gen_random_uuid();
 INSERT INTO public.wms_transfer_scope_context(transaction_id,transfer_id,actor_id,context_type) VALUES(txid_current(),p_transfer_id,v_user,'REJECT_RECEIPT');
 INSERT INTO public.transactions(id,reference_no,transaction_type,status,warehouse_id,storage_area_id,notes,created_by)
 VALUES(v_tx,v_transfer.reference_no||'-REJECT-RETURN','ADJUSTMENT_IN','APPROVED',v_shelf.warehouse_id,v_area,'Rejected transfer receipt; goods returned to source. Reason: '||btrim(p_reason),v_user);
 INSERT INTO public.transaction_lines(transaction_id,item_id,shelf_id,administrative_department_id,quantity,balance_before,balance_after,batch_no,expiry_date,storage_area_id,notes)
 VALUES(v_tx,v_transfer.item_id,v_transfer.source_shelf_id,v_owner,v_transfer.quantity,v_before,v_after,v_transfer.batch_no,v_transfer.expiry_date,v_area,'Transfer='||p_transfer_id::text||'; direction=REJECTED_RETURN; reason='||btrim(p_reason));
 DELETE FROM public.wms_transfer_scope_context WHERE transaction_id=txid_current() AND transfer_id=p_transfer_id AND actor_id=v_user AND context_type='REJECT_RECEIPT';
 INSERT INTO public.stock(item_id,shelf_id,administrative_department_id,quantity,batch_no,expiry_date,storage_area_id,updated_at)
 VALUES(v_transfer.item_id,v_transfer.source_shelf_id,v_owner,v_after,v_transfer.batch_no,v_transfer.expiry_date,v_area,now())
 ON CONFLICT (item_id, shelf_id, batch_no, administrative_department_id) DO UPDATE SET quantity=EXCLUDED.quantity,expiry_date=COALESCE(EXCLUDED.expiry_date,public.stock.expiry_date),storage_area_id=COALESCE(EXCLUDED.storage_area_id,public.stock.storage_area_id),updated_at=now();
 PERFORM public.log_transaction_ledger(p_transaction_id:=v_tx,p_ledger_type:='STOCK_TRANSFER',p_user_id:=v_user,p_warehouse_id:=v_shelf.warehouse_id,p_zone_id:=NULL::uuid,p_section_id:=NULL::uuid,p_shelf_id:=v_transfer.source_shelf_id,p_item_id:=v_transfer.item_id,p_quantity:=v_transfer.quantity,p_balance_before:=v_before,p_balance_after:=v_after,p_transaction_type:='ADJUSTMENT_IN',p_details:=jsonb_build_object('transfer_id',p_transfer_id,'rejected_at_destination',v_transfer.destination_warehouse_id,'reason',btrim(p_reason),'batch_no',v_transfer.batch_no,'administrative_department_id',v_owner,'storage_area_id',v_area),p_reference:=v_transfer.reference_no,p_approved:=true,p_reference_type:='STOCK_TRANSFER_REJECTED_RETURN',p_batch_no:=v_transfer.batch_no,p_expiry_date:=v_transfer.expiry_date);
 UPDATE public.stock_transfers SET status='REJECTED',rejected_by=v_user,rejected_at=now(),rejection_reason=btrim(p_reason),rejection_transaction_id=v_tx,notes=concat_ws(E'\n',NULLIF(notes,''),'REJECTED: '||btrim(p_reason)),updated_at=now() WHERE id=p_transfer_id;
 INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,reference,details)
 VALUES(v_user,'STOCK_TRANSFER_RECEIPT_REJECTED','STOCK_TRANSFER',p_transfer_id::text,v_shelf.warehouse_id,v_transfer.reference_no,jsonb_build_object('reason',btrim(p_reason),'quantity_returned_to_source',v_transfer.quantity,'source_balance_after',v_after,'destination_warehouse_id',v_transfer.destination_warehouse_id,'administrative_department_id',v_owner));
 RETURN jsonb_build_object('success',true,'already_rejected',false,'transfer_id',p_transfer_id,'status','REJECTED','destination_transaction_id',v_tx,'source_balance_after',v_after);
END;$function$
;

CREATE OR REPLACE FUNCTION public.finalize_stock_transfer_source_issue(p_transfer_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
                             DECLARE
                               v_t public.stock_transfers%ROWTYPE;
                                 v_tx_status text;
                                   v_line record;
                                 v_updated boolean;
                                   BEGIN
                                     IF p_transfer_id IS NULL OR p_user_id IS NULL THEN
                                         RAISE EXCEPTION 'Transfer ID and acting user are required';
                                           END IF;
                                             SELECT * INTO v_t FROM public.stock_transfers WHERE id=p_transfer_id FOR UPDATE;
                                               IF NOT FOUND THEN RAISE EXCEPTION 'Stock transfer line not found'; END IF;
                                                 IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_user_id OR NOT public.current_user_is_active()
                                                    OR NOT (public.current_user_can_access_warehouse(v_t.source_warehouse_id) OR public.current_user_can_access_warehouse(v_t.destination_warehouse_id)) THEN
                                                   RAISE EXCEPTION 'User is not assigned to either transfer warehouse' USING ERRCODE='42501';
                                                 END IF;

                                                 IF COALESCE(v_t.received_quantity,0)+COALESCE(v_t.returned_quantity,0) < v_t.quantity THEN
                                                     RETURN false;
                                                       END IF;
                                                         IF v_t.source_transaction_id IS NULL THEN
                                                             RAISE EXCEPTION 'Source issue transaction is missing for transfer %',p_transfer_id;
                                                               END IF;

                                                                 INSERT INTO public.wms_transfer_scope_context(transaction_id,transfer_id,actor_id,context_type) VALUES(txid_current(),p_transfer_id,auth.uid(),'FINALIZE_SOURCE');
                                                                 UPDATE public.transactions
                                                                      SET status='APPROVED'
                                                                         WHERE id=v_t.source_transaction_id AND status='PENDING_RECEIPT';
                                                                 v_updated := FOUND;
                                                                 DELETE FROM public.wms_transfer_scope_context WHERE transaction_id=txid_current() AND transfer_id=p_transfer_id AND actor_id=auth.uid() AND context_type='FINALIZE_SOURCE';

                                                                           IF v_updated THEN
                                                                               UPDATE public.transaction_ledger
                                                                                      SET approved=true, approved_at=now(), administrative_department_id=v_t.administrative_department_id
                                                                                           WHERE transaction_id=v_t.source_transaction_id AND approved IS DISTINCT FROM true;

                                                                                               FOR v_line IN
                                                                                                     SELECT t.id AS transaction_id,t.reference_no,t.warehouse_id,NULL::uuid AS zone_id,NULL::uuid AS section_id,t.storage_area_id,
                                                                                                                  t.created_by,t.created_at,tl.item_id,tl.shelf_id,tl.quantity,tl.balance_after,tl.batch_no,
                                                                                                                               tl.expiry_date,tl.storage_area_id AS line_storage_area_id,tl.administrative_department_id,tl.notes,
                                                                                                                                            i.code AS item_code,i.name_en AS item_name,i.base_unit
                                                                                                                                                    FROM public.transactions t
                                                                                                                                                            JOIN public.transaction_lines tl ON tl.transaction_id=t.id
                                                                                                                                                                    JOIN public.items i ON i.id=tl.item_id
                                                                                                                                                                           WHERE t.id=v_t.source_transaction_id
                                                                                                                                                                               LOOP
                                                                                                                                                                                     -- Keep the ledger event's effective time at dispatch time. The row is approved now, but
                                                                                                                                                                                           -- stock was physically deducted when the transfer was dispatched; later movements' stored
                                                                                                                                                                                                 -- running balances therefore remain chronologically consistent.
                                                                                                                                                                                                       INSERT INTO public.inventory_ledger(
                                                                                                                                                                                                               occurred_at,item_id,item_code,item_name,warehouse_id,shelf_id,
                                                                                                                                                                                                                       delta,unit,source_type,source_id,source_ref,running_balance,created_by,notes,metadata,
                                                                                                                                                                                                                               batch_no,expiry_date,storage_area_id,administrative_department_id
                                                                                                                                                                                                                                     ) VALUES (
                                                                                                                                                                                                                                             v_line.created_at,v_line.item_id,COALESCE(v_line.item_code,''),COALESCE(v_line.item_name,''),
                                                                                                                                                                                                                                                     v_line.warehouse_id,v_line.shelf_id,-v_line.quantity,
                                                                                                                                                                                                                                                             COALESCE(v_line.base_unit,'PCS'),'TRANSFER_OUT',v_line.transaction_id,v_line.reference_no,
                                                                                                                                                                                                                                                                     v_line.balance_after,v_line.created_by,
                                                                                                                                                                                                                                                                             'Transfer issue finalized after all quantities were received or physically returned. '||COALESCE(v_line.notes,''),
                                                                                                                                                                                                                                                                                     jsonb_build_object('transfer_id',p_transfer_id,'finalized_after_receipt_or_return',true,
                                                                                                                                                                                                                                                                                               'finalized_by',p_user_id,'batch_no',v_line.batch_no,'expiry_date',v_line.expiry_date),
                                                                                                                                                                                                                                                                                                       v_line.batch_no,v_line.expiry_date,COALESCE(v_line.line_storage_area_id,v_line.storage_area_id),v_line.administrative_department_id
                                                                                                                                                                                                                                                                                                             );
                                                                                                                                                                                                                                                                                                                 END LOOP;

                                                                                                                                                                                                                                                                                                                     INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,reference,details)
                                                                                                                                                                                                                                                                                                                         VALUES(p_user_id,'STOCK_TRANSFER_SOURCE_ISSUE_FINALIZED','STOCK_TRANSFER',p_transfer_id::text,
                                                                                                                                                                                                                                                                                                                                    v_t.source_warehouse_id,v_t.reference_no,
                                                                                                                                                                                                                                                                                                                                               jsonb_build_object('source_transaction_id',v_t.source_transaction_id,
                                                                                                                                                                                                                                                                                                                                                            'dispatched_quantity',v_t.quantity,'received_quantity',COALESCE(v_t.received_quantity,0),
                                                                                                                                                                                                                                                                                                                                                                         'returned_quantity',COALESCE(v_t.returned_quantity,0),'status',v_t.status)::text);
                                                                                                                                                                                                                                                                                                                                                                             RETURN true;
                                                                                                                                                                                                                                                                                                                                                                               END IF;

                                                                                                                                                                                                                                                                                                                                                                                 SELECT status INTO v_tx_status FROM public.transactions WHERE id=v_t.source_transaction_id;
                                                                                                                                                                                                                                                                                                                                                                                   IF v_tx_status='APPROVED' THEN RETURN true; END IF;
                                                                                                                                                                                                                                                                                                                                                                                     RAISE EXCEPTION 'Source issue cannot be finalized from status %',COALESCE(v_tx_status,'<missing>');
                                                                                                                                                                                                                                                                                                                                                                                     END;
                                                                                                                                                                                                                                                                                                                                                                                     $function$
;

CREATE OR REPLACE FUNCTION public.list_stocktake_lines_secure()
 RETURNS TABLE(id uuid, session_id uuid, item_id uuid, shelf_id uuid, system_qty numeric, counted_qty numeric, variance numeric, is_settled boolean, settled_at timestamp with time zone, created_at timestamp with time zone, batch_no text, expiry_date date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_role text;
  v_status text;
  v_assigned uuid[];
  v_custom text[];
  v_can_view boolean := false;
  v_can_view_system boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'An authenticated user is required';
  END IF;

  SELECT p.role,p.status,p.assigned_warehouse_ids,COALESCE(p.custom_permissions,ARRAY[]::text[])
    INTO v_role,v_status,v_assigned,v_custom
  FROM public.profiles p WHERE p.id=v_user_id;

  IF NOT FOUND OR v_status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'An active authenticated user is required';
  END IF;

  v_can_view :=
    v_role IN ('SUPER_ADMIN','ADMIN','MANAGER')
    OR v_custom && ARRAY[
      'page:stocktake:access','table:stocktake:view',
      'action:stocktake:start','action:stocktake:count',
      'action:stocktake:submit','action:stocktake:approve',
      'action:stocktake:settle','action:stocktake:close'
    ]::text[]
    OR EXISTS (
      SELECT 1 FROM public.role_permissions rp
      WHERE rp.role_name=v_role
        AND rp.permission_key IN (
          'page:stocktake:access','table:stocktake:view',
          'action:stocktake:start','action:stocktake:count',
          'action:stocktake:submit','action:stocktake:approve',
          'action:stocktake:settle','action:stocktake:close'
        )
    );

  IF NOT v_can_view THEN
    RAISE EXCEPTION 'You do not have permission to view stocktake lines';
  END IF;

  v_can_view_system :=
    v_role IN ('SUPER_ADMIN','ADMIN','MANAGER')
    OR v_custom @> ARRAY['action:stocktake:view_system_qty']::text[]
    OR EXISTS (
      SELECT 1 FROM public.role_permissions rp
      WHERE rp.role_name=v_role AND rp.permission_key='action:stocktake:view_system_qty'
    );

  RETURN QUERY
  SELECT l.id,l.session_id,l.item_id,l.shelf_id,
    CASE WHEN v_can_view_system THEN l.system_qty ELSE NULL::numeric END,
    l.counted_qty,
    CASE WHEN v_can_view_system THEN l.variance ELSE NULL::numeric END,
    l.is_settled,l.settled_at,l.created_at,l.batch_no,l.expiry_date
  FROM public.stocktake_lines l
  JOIN public.stocktake_sessions s ON s.id=l.session_id
  WHERE public.current_user_can_access_warehouse(s.warehouse_id);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_stock_summary_by_storage_area(p_start_date timestamp with time zone, p_end_date timestamp with time zone, p_warehouse_id uuid DEFAULT NULL::uuid, p_storage_area_id uuid DEFAULT NULL::uuid, p_category_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(item_code text, item_name_en text, item_name_ar text, category_name text, opening_stock numeric, total_in numeric, total_out numeric, current_stock numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_role text;
  v_status text;
  v_assigned uuid[];
BEGIN
  IF v_user_id IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'An active authenticated user is required';
  END IF;
  IF NOT (
    public.current_user_has_permission('page:reports:access')
    OR public.current_user_has_permission('table:reports:view')
  ) THEN
    RAISE EXCEPTION 'You do not have permission to view stock summary reports';
  END IF;
  SELECT p.role,p.status,COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[])
    INTO v_role,v_status,v_assigned
  FROM public.profiles p WHERE p.id=v_user_id;
  IF NOT FOUND OR v_status<>'ACTIVE' THEN
    RAISE EXCEPTION 'Active user profile required';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date<p_start_date THEN
    RAISE EXCEPTION 'A valid report date range is required';
  END IF;
  IF cardinality(v_assigned)>0 THEN
    IF p_warehouse_id IS NULL OR NOT public.current_user_can_access_warehouse(p_warehouse_id) THEN
      RAISE EXCEPTION 'Select a warehouse assigned to your account';
    END IF;
  ELSE
    IF v_role NOT IN ('SUPER_ADMIN','ADMIN') THEN
      RAISE EXCEPTION 'No warehouse is assigned to this account';
    END IF;
    IF p_warehouse_id IS NOT NULL AND NOT public.current_user_can_access_warehouse(p_warehouse_id) THEN
      RAISE EXCEPTION 'Report warehouse is outside the current user assigned scope';
    END IF;
  END IF;
  IF p_storage_area_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.storage_areas a
    WHERE a.id=p_storage_area_id AND a.is_active=true
      AND (p_warehouse_id IS NULL OR a.warehouse_id=p_warehouse_id)
      AND public.current_user_can_access_warehouse(a.warehouse_id)
  ) THEN
    RAISE EXCEPTION 'Storage area is not active in the selected warehouse';
  END IF;

  RETURN QUERY
  WITH ledger_summary AS (
    SELECT il.item_id,
      SUM(CASE
        WHEN il.is_opening_balance=TRUE OR il.occurred_at<p_start_date
        THEN il.delta ELSE 0 END) AS opening,
      SUM(CASE
        WHEN il.is_opening_balance=FALSE
          AND il.occurred_at>=p_start_date AND il.occurred_at<=p_end_date
          AND il.delta>0
          AND NOT (
            COALESCE(il.metadata,'{}'::jsonb) ? 'transfer_id'
            OR COALESCE(il.metadata->>'reference_type','') LIKE 'STOCK_TRANSFER%'
            OR COALESCE(il.notes,'') ILIKE '%Transfer=%'
            OR COALESCE(il.source_ref,'') ~* '^TRF[-_].*-(OUT|IN|RET-RCV)$'
          )
        THEN il.delta ELSE 0 END) AS qty_in,
      SUM(CASE
        WHEN il.is_opening_balance=FALSE
          AND il.occurred_at>=p_start_date AND il.occurred_at<=p_end_date
          AND il.delta<0
          AND NOT (
            COALESCE(il.metadata,'{}'::jsonb) ? 'transfer_id'
            OR COALESCE(il.metadata->>'reference_type','') LIKE 'STOCK_TRANSFER%'
            OR COALESCE(il.notes,'') ILIKE '%Transfer=%'
            OR COALESCE(il.source_ref,'') ~* '^TRF[-_].*-(OUT|IN|RET-RCV)$'
          )
        THEN ABS(il.delta) ELSE 0 END) AS qty_out
    FROM public.inventory_ledger il
    WHERE (p_warehouse_id IS NULL OR il.warehouse_id=p_warehouse_id)
      AND (p_storage_area_id IS NULL OR il.storage_area_id=p_storage_area_id)
    GROUP BY il.item_id
  ),
  current_stock_actual AS (
    SELECT s.item_id,SUM(s.quantity) AS total_qty
    FROM public.stock s
    LEFT JOIN public.shelves sh ON sh.id=s.shelf_id
    WHERE (p_warehouse_id IS NULL OR sh.warehouse_id=p_warehouse_id)
      AND (p_storage_area_id IS NULL OR s.storage_area_id=p_storage_area_id)
    GROUP BY s.item_id
  )
  SELECT i.code,i.name_en,i.name_ar,
    COALESCE(ic.name,NULLIF(i.category,''),'-'),
    COALESCE(ls.opening,0),COALESCE(ls.qty_in,0),COALESCE(ls.qty_out,0),COALESCE(csa.total_qty,0)
  FROM public.items i
  LEFT JOIN public.item_categories ic ON ic.id=i.category_id
  LEFT JOIN ledger_summary ls ON ls.item_id=i.id
  LEFT JOIN current_stock_actual csa ON csa.item_id=i.id
  WHERE i.status='ACTIVE'
    AND (p_category_id IS NULL OR i.category_id=p_category_id)
    AND (ls.item_id IS NOT NULL OR csa.item_id IS NOT NULL)
  ORDER BY i.code;
END;
$function$
;

COMMIT;
