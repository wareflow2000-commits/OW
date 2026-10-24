-- ORSHAP WMS v13.9.58
-- Enforce warehouse assignment at the RLS boundary, not only in UI/RPC validation.
-- SUPER_ADMIN, ADMIN and MANAGER retain global scope; all other roles are restricted
-- to assigned warehouses, including WAREHOUSE_MANAGER.
DO $migration$
BEGIN
  DROP POLICY IF EXISTS warehouses_active_read ON public.warehouses;
  CREATE POLICY warehouses_active_read ON public.warehouses
    FOR SELECT TO authenticated
    USING (
      public.current_user_is_active()
      AND EXISTS (
        SELECT 1 FROM public.profiles p
         WHERE p.id=(SELECT auth.uid())
           AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
                OR public.warehouses.id = ANY(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[])))
      )
    );

  DROP POLICY IF EXISTS storage_areas_active_read ON public.storage_areas;
  CREATE POLICY storage_areas_active_read ON public.storage_areas
    FOR SELECT TO authenticated
    USING (
      public.current_user_is_active()
      AND EXISTS (
        SELECT 1 FROM public.profiles p
         WHERE p.id=(SELECT auth.uid())
           AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
                OR public.storage_areas.warehouse_id = ANY(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[])))
      )
    );

  DROP POLICY IF EXISTS shelves_active_read ON public.shelves;
  CREATE POLICY shelves_active_read ON public.shelves
    FOR SELECT TO authenticated
    USING (
      public.current_user_is_active()
      AND EXISTS (
        SELECT 1 FROM public.profiles p
         WHERE p.id=(SELECT auth.uid())
           AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
                OR public.shelves.warehouse_id = ANY(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[])))
      )
    );

  DROP POLICY IF EXISTS transactions_permission_select ON public.transactions;
  CREATE POLICY transactions_permission_select ON public.transactions
    FOR SELECT TO authenticated
    USING (
      public.current_user_has_permission('table:transactions:view')
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
      AND (
        created_by = (SELECT auth.uid())
        OR public.current_user_has_permission('action:transaction:view_others')
      )
    );

  DROP POLICY IF EXISTS transactions_permission_insert ON public.transactions;
  CREATE POLICY transactions_permission_insert ON public.transactions
    FOR INSERT TO authenticated
    WITH CHECK (
      created_by = (SELECT auth.uid())
      AND status = 'PENDING_APPROVAL'
      AND CASE transaction_type
        WHEN 'GRN' THEN public.current_user_has_permission('action:transaction:grn:create')
        WHEN 'RETURN_FROM_USAGE' THEN public.current_user_has_permission('action:transaction:grn:create')
        WHEN 'RETURN_FROM_CUSTOMER' THEN public.current_user_has_permission('action:transaction:grn:create')
        WHEN 'ISSUE' THEN public.current_user_has_permission('action:transaction:issue:create')
        WHEN 'RETURN_TO_SUPPLIER' THEN public.current_user_has_permission('action:transaction:issue:create')
        WHEN 'ADJUSTMENT_IN' THEN public.current_user_has_permission('action:transaction:adjustment:create')
        WHEN 'ADJUSTMENT_OUT' THEN public.current_user_has_permission('action:transaction:adjustment:create')
        WHEN 'OPENING_BALANCE' THEN public.current_user_is_manager()
        ELSE false
      END
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
    );

  DROP POLICY IF EXISTS transactions_permission_update ON public.transactions;
  CREATE POLICY transactions_permission_update ON public.transactions
    FOR UPDATE TO authenticated
    USING (
      status='PENDING_APPROVAL'
      AND (created_by=(SELECT auth.uid()) OR public.current_user_is_manager())
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
    )
    WITH CHECK (
      status='PENDING_APPROVAL'
      AND (created_by=(SELECT auth.uid()) OR public.current_user_is_manager())
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
    );

  DROP POLICY IF EXISTS transactions_permission_delete ON public.transactions;
  CREATE POLICY transactions_permission_delete ON public.transactions
    FOR DELETE TO authenticated
    USING (
      status='PENDING_APPROVAL'
      AND (created_by=(SELECT auth.uid()) OR public.current_user_is_manager())
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
    );

  DROP POLICY IF EXISTS inventory_ledger_select_policy ON public.inventory_ledger;
  CREATE POLICY inventory_ledger_select_policy ON public.inventory_ledger
    FOR SELECT TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.profiles p
         WHERE p.id=(SELECT auth.uid()) AND p.status='ACTIVE'
           AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER','WAREHOUSE_MANAGER')
                OR COALESCE(p.custom_permissions,ARRAY[]::text[]) @> ARRAY['VIEW_LEDGER']::text[])
           AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
                OR public.inventory_ledger.warehouse_id = ANY(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[])))
      )
    );

  DROP POLICY IF EXISTS transaction_ledger_authenticated_read ON public.transaction_ledger;
  CREATE POLICY transaction_ledger_authenticated_read ON public.transaction_ledger
    FOR SELECT TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.profiles p
         WHERE p.id=(SELECT auth.uid()) AND p.status='ACTIVE'
           AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER','WAREHOUSE_MANAGER')
                OR COALESCE(p.custom_permissions,ARRAY[]::text[]) @> ARRAY['VIEW_LEDGER','VIEW_AUDIT']::text[])
           AND (p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
                OR public.transaction_ledger.warehouse_id = ANY(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[])))
      )
    );

  DROP POLICY IF EXISTS stocktake_sessions_permission_select ON public.stocktake_sessions;
  CREATE POLICY stocktake_sessions_permission_select ON public.stocktake_sessions
    FOR SELECT TO authenticated
    USING (
      (public.current_user_has_permission('page:stocktake:access')
       OR public.current_user_has_permission('table:stocktake:view'))
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
    );

  DROP POLICY IF EXISTS stocktake_lines_permission_select ON public.stocktake_lines;
  CREATE POLICY stocktake_lines_permission_select ON public.stocktake_lines
    FOR SELECT TO authenticated
    USING (
      (public.current_user_has_permission('page:stocktake:access')
       OR public.current_user_has_permission('table:stocktake:view'))
      AND EXISTS (
        SELECT 1 FROM public.stocktake_sessions s
         WHERE s.id=stocktake_lines.session_id
      )
    );

  DROP POLICY IF EXISTS stocktake_logs_permission_select ON public.stocktake_logs;
  CREATE POLICY stocktake_logs_permission_select ON public.stocktake_logs
    FOR SELECT TO authenticated
    USING (
      (public.current_user_has_permission('page:stocktake:access')
       OR public.current_user_has_permission('table:stocktake:view'))
      AND EXISTS (
        SELECT 1 FROM public.stocktake_sessions s
         WHERE s.id=stocktake_logs.session_id
      )
    );

  -- Scope stocktake creation/maintenance as well; subqueries from line policies
  -- inherit the warehouse-filtered session visibility above.
  DROP POLICY IF EXISTS stocktake_sessions_permission_insert ON public.stocktake_sessions;
  CREATE POLICY stocktake_sessions_permission_insert ON public.stocktake_sessions
    FOR INSERT TO authenticated
    WITH CHECK (
      created_by=(SELECT auth.uid()) AND status='IN_PROGRESS'
      AND public.current_user_has_permission('action:stocktake:start')
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
    );

  DROP POLICY IF EXISTS stocktake_sessions_permission_update ON public.stocktake_sessions;
  CREATE POLICY stocktake_sessions_permission_update ON public.stocktake_sessions
    FOR UPDATE TO authenticated
    USING (
      status='IN_PROGRESS'
      AND (created_by=(SELECT auth.uid()) OR public.current_user_is_manager())
      AND public.current_user_has_permission('action:stocktake:start')
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
    )
    WITH CHECK (
      status='IN_PROGRESS'
      AND (created_by=(SELECT auth.uid()) OR public.current_user_is_manager())
      AND public.current_user_has_permission('action:stocktake:start')
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
    );

  DROP POLICY IF EXISTS stocktake_sessions_permission_delete ON public.stocktake_sessions;
  CREATE POLICY stocktake_sessions_permission_delete ON public.stocktake_sessions
    FOR DELETE TO authenticated
    USING (
      status='IN_PROGRESS'
      AND public.current_user_is_manager()
      AND (
        EXISTS (SELECT 1 FROM public.profiles p
                 WHERE p.id=(SELECT auth.uid())
                   AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER'))
        OR warehouse_id = ANY(COALESCE(
             (SELECT p.assigned_warehouse_ids FROM public.profiles p WHERE p.id=(SELECT auth.uid())),
             ARRAY[]::uuid[]))
      )
    );
END;
$migration$;
