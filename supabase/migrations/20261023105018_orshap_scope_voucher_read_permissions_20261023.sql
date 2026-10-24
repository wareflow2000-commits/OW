-- Restrict voucher reads to own records unless the caller has the explicit view-others permission.
DROP POLICY IF EXISTS transactions_permission_select ON public.transactions;
CREATE POLICY transactions_permission_select ON public.transactions
FOR SELECT TO authenticated
USING (
  public.current_user_has_permission('table:transactions:view')
  AND (
    created_by = (SELECT auth.uid())
    OR public.current_user_has_permission('action:transaction:view_others')
  )
);

DROP POLICY IF EXISTS transaction_lines_permission_select ON public.transaction_lines;
CREATE POLICY transaction_lines_permission_select ON public.transaction_lines
FOR SELECT TO authenticated
USING (
  public.current_user_has_permission('table:transactions:view')
  AND EXISTS (
    SELECT 1 FROM public.transactions t
    WHERE t.id = transaction_lines.transaction_id
      AND (
        t.created_by = (SELECT auth.uid())
        OR public.current_user_has_permission('action:transaction:view_others')
      )
  )
);

-- Sequence access is needed only by the SECURITY DEFINER reference generator.
REVOKE ALL ON SEQUENCE public.transaction_reference_seq FROM PUBLIC;
REVOKE ALL ON SEQUENCE public.transaction_reference_seq FROM anon;
REVOKE ALL ON SEQUENCE public.transaction_reference_seq FROM authenticated;
