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
            OR COALESCE(il.source_ref,'') ~* '^TRF[-_].*-(OUT|IN|RET-RCV)
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
            OR COALESCE(il.source_ref,'') ~* '^TRF[-_].*-(OUT|IN|RET-RCV)
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


COMMIT;
