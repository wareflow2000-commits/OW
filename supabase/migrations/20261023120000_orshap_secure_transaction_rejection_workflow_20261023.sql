-- Enforce rejection permissions in the database rather than direct client status updates.
CREATE OR REPLACE FUNCTION public.reject_transaction(p_transaction_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_profile public.profiles%ROWTYPE;
  v_tx public.transactions%ROWTYPE;
BEGIN
  IF v_user IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'Active authenticated user required';
  END IF;
  IF NULLIF(btrim(COALESCE(p_reason,'')),'') IS NULL THEN
    RAISE EXCEPTION 'A rejection reason is required';
  END IF;
  SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';
  IF NOT FOUND THEN RAISE EXCEPTION 'Active user profile required'; END IF;
  IF NOT public.current_user_has_permission('action:transaction:reject')
     AND v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') THEN
    RAISE EXCEPTION 'Permission denied to reject transactions';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id=p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  IF v_tx.status <> 'PENDING_APPROVAL' THEN
    RAISE EXCEPTION 'Only a pending transaction can be rejected; current status: %',v_tx.status;
  END IF;
  IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER')
     AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0
       OR NOT (v_tx.warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN
    RAISE EXCEPTION 'User is not assigned to the transaction warehouse';
  END IF;
  UPDATE public.transactions
     SET status='REJECTED', rejection_reason=btrim(p_reason)
   WHERE id=p_transaction_id AND status='PENDING_APPROVAL';
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction state changed before rejection'; END IF;
  INSERT INTO public.audit_logs(user_id,action,entity,entity_id,warehouse_id,reference,details)
  VALUES(v_user,'REJECT_TRANSACTION','TRANSACTION',p_transaction_id::text,v_tx.warehouse_id,
         v_tx.reference_no,jsonb_build_object('reason',btrim(p_reason),'previous_status',v_tx.status,'new_status','REJECTED')::text);
  RETURN jsonb_build_object('success',true,'transaction_id',p_transaction_id,'status','REJECTED');
END;
$function$;

REVOKE ALL ON FUNCTION public.reject_transaction(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_transaction(uuid,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.reject_transaction(uuid,text) TO authenticated;

DROP POLICY IF EXISTS transactions_permission_update ON public.transactions;
CREATE POLICY transactions_permission_update ON public.transactions
FOR UPDATE TO authenticated
USING (
  status = 'PENDING_APPROVAL'
  AND (created_by = (SELECT auth.uid()) OR (SELECT public.current_user_is_manager()))
)
WITH CHECK (
  status = 'PENDING_APPROVAL'
  AND (created_by = (SELECT auth.uid()) OR (SELECT public.current_user_is_manager()))
);
