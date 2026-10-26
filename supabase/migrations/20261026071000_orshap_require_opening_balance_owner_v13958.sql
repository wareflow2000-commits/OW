-- ORSHAP WMS v13.9.58: require owning department on every opening-balance line.
-- The dedicated opening-balance RPC already validates this; align generic RPC and approval.
BEGIN;
DO $patch$
DECLARE
  r record;
  v_body text;
  v_new_body text;
  v_def text;
  v_new_def text;
  v_count integer;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.create_transaction_with_lines(uuid,jsonb,jsonb)'::regprocedure,
     $a$IF v_type IN ('GRN','ISSUE','ADJUSTMENT_IN','ADJUSTMENT_OUT','RETURN_FROM_USAGE','RETURN_FROM_CUSTOMER','RETURN_TO_SUPPLIER')
       AND v_line.administrative_department_id IS NULL THEN
      RAISE EXCEPTION 'Owning department is required for each stock transaction line';$a$,
     $b$IF v_type IN ('GRN','ISSUE','ADJUSTMENT_IN','ADJUSTMENT_OUT','RETURN_FROM_USAGE','RETURN_FROM_CUSTOMER','RETURN_TO_SUPPLIER','OPENING_BALANCE')
       AND (v_line.administrative_department_id IS NULL OR NOT EXISTS (
         SELECT 1 FROM public.administrative_departments d
         WHERE d.id = v_line.administrative_department_id AND d.is_active = true
       )) THEN
      RAISE EXCEPTION 'Owning department is required for each stock transaction line';$b$),
    ('public.approve_transaction(uuid)'::regprocedure,
     $a$IF v_tx_rec.transaction_type IN ('GRN', 'ISSUE', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT', 'RETURN_FROM_USAGE', 'RETURN_FROM_CUSTOMER', 'RETURN_TO_SUPPLIER') AND v_rec.administrative_department_id IS NULL THEN RAISE EXCEPTION 'Owning department is required for each stock transaction line'; END IF;$a$,
     $b$IF v_tx_rec.transaction_type IN ('GRN', 'ISSUE', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT', 'RETURN_FROM_USAGE', 'RETURN_FROM_CUSTOMER', 'RETURN_TO_SUPPLIER', 'OPENING_BALANCE') AND (v_rec.administrative_department_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.administrative_departments d WHERE d.id = v_rec.administrative_department_id AND d.is_active = true)) THEN RAISE EXCEPTION 'Owning department is required for each stock transaction line'; END IF;$b$)
  ) AS x(fn,anchor,replacement)
  LOOP
    SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid=r.fn::oid;
    v_count := (length(v_body)-length(replace(v_body,r.anchor,'')))/length(r.anchor);
    IF v_count<>1 THEN RAISE EXCEPTION 'Expected exactly one owning-department validation anchor in %, found %',r.fn,v_count; END IF;
    v_new_body:=replace(v_body,r.anchor,r.replacement);
    v_def:=pg_get_functiondef(r.fn::oid);
    v_new_def:=replace(v_def,v_body,v_new_body);
    IF v_new_def=v_def THEN RAISE EXCEPTION 'Could not reconstruct function definition for %',r.fn; END IF;
    EXECUTE v_new_def;
  END LOOP;
END
$patch$;

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
      WHEN 'OPENING_BALANCE' THEN current_user_has_permission('action:transaction:adjustment:create')
        AND EXISTS (
          SELECT 1 FROM public.profiles p
          WHERE p.id = (SELECT auth.uid()) AND p.role IN ('SUPER_ADMIN','MANAGER')
        )
      ELSE false
    END
    AND current_user_can_access_warehouse(warehouse_id)
  );
COMMIT;
