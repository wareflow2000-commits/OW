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
            AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')))
  ) END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_transaction_warehouse_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF TG_OP <> 'INSERT' AND NOT public.current_user_can_access_warehouse(OLD.warehouse_id) THEN
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED: transaction is outside the current user assigned warehouses' USING ERRCODE='42501';
  END IF;
  IF NOT public.current_user_can_access_warehouse(NEW.warehouse_id) THEN
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED: transaction warehouse is not assigned to the current user' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_enforce_transaction_warehouse_scope ON public.transactions;
CREATE TRIGGER trg_enforce_transaction_warehouse_scope BEFORE INSERT OR UPDATE ON public.transactions
FOR EACH ROW EXECUTE FUNCTION public.enforce_transaction_warehouse_scope();

CREATE OR REPLACE FUNCTION public.enforce_transaction_line_warehouse_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_tx_id uuid; v_warehouse_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW; END IF;
  v_tx_id := CASE WHEN TG_OP='DELETE' THEN OLD.transaction_id ELSE NEW.transaction_id END;
  SELECT t.warehouse_id INTO v_warehouse_id FROM public.transactions t WHERE t.id=v_tx_id;
  -- A cascading delete may execute after its parent row is no longer visible; the FK
  -- guarantees the deleted line belonged to that parent, so allow only that delete case.
  IF v_warehouse_id IS NULL AND TG_OP='DELETE' THEN RETURN OLD; END IF;
  IF v_warehouse_id IS NULL OR NOT public.current_user_can_access_warehouse(v_warehouse_id) THEN
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED: transaction line is outside the current user assigned warehouses' USING ERRCODE='42501';
  END IF;
  IF TG_OP='UPDATE' AND OLD.transaction_id IS DISTINCT FROM NEW.transaction_id THEN
    RAISE EXCEPTION 'Transaction lines cannot be moved between transactions';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END;
$$;
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
AS $
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id=(SELECT auth.uid()) AND p.status='ACTIVE'
      AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
      AND cardinality(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[]))=0
      AND public.current_user_has_permission('action:warehouse:manage')
  );
$;

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
COMMIT;
