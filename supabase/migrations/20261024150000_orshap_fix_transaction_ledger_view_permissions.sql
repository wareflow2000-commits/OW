-- ORSHAP WMS v13.9.58
-- VIEW_LEDGER and VIEW_AUDIT are alternative grants, not a combined requirement.
DROP POLICY IF EXISTS transaction_ledger_authenticated_read ON public.transaction_ledger;

CREATE POLICY transaction_ledger_authenticated_read
ON public.transaction_ledger
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
      FROM public.profiles p
     WHERE p.id=(SELECT auth.uid())
       AND p.status='ACTIVE'
       AND (
         p.role IN ('SUPER_ADMIN','ADMIN','MANAGER','WAREHOUSE_MANAGER')
         OR COALESCE(p.custom_permissions,ARRAY[]::text[]) @> ARRAY['VIEW_LEDGER']::text[]
         OR COALESCE(p.custom_permissions,ARRAY[]::text[]) @> ARRAY['VIEW_AUDIT']::text[]
       )
       AND (
         p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
         OR public.transaction_ledger.warehouse_id = ANY(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[]))
       )
  )
);
