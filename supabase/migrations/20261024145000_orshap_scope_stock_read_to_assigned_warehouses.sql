-- ORSHAP WMS v13.9.58
-- Inventory permission alone must not expose stock from warehouses outside the
-- authenticated user's assignment scope. Admin roles retain their global scope.
DROP POLICY IF EXISTS stock_authenticated_read ON public.stock;

CREATE POLICY stock_authenticated_read
ON public.stock
FOR SELECT
TO authenticated
USING (
  public.current_user_has_permission('table:inventory:view')
  AND EXISTS (
    SELECT 1
      FROM public.shelves sh
     WHERE sh.id = stock.shelf_id
       AND (
         EXISTS (
           SELECT 1
             FROM public.profiles p
            WHERE p.id = (SELECT auth.uid())
              AND p.role IN ('SUPER_ADMIN','ADMIN','MANAGER')
         )
         OR sh.warehouse_id = ANY(
           COALESCE(
             (SELECT p.assigned_warehouse_ids
                FROM public.profiles p
               WHERE p.id = (SELECT auth.uid())),
             ARRAY[]::uuid[]
           )
         )
       )
  )
);
