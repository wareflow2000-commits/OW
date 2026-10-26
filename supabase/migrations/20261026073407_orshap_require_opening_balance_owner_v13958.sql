-- ORSHAP WMS v13.9.58: require an active owning department on every opening-balance line.
-- Match the validation clauses structurally; pg_proc.prosrc whitespace differs across deployed revisions.
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
    (
      'public.create_transaction_with_lines(uuid,jsonb,jsonb)'::regprocedure,
      $pattern$IF\s+v_type\s+IN\s*\([^)]*\)\s+AND\s+v_line\.administrative_department_id\s+IS\s+NULL\s+THEN\s+RAISE EXCEPTION 'Owning department is required for each stock transaction line';$pattern$,
      $replacement$IF v_type IN ('GRN','ISSUE','ADJUSTMENT_IN','ADJUSTMENT_OUT','RETURN_FROM_USAGE','RETURN_FROM_CUSTOMER','RETURN_TO_SUPPLIER','OPENING_BALANCE')
       AND (v_line.administrative_department_id IS NULL OR NOT EXISTS (
         SELECT 1 FROM public.administrative_departments d
         WHERE d.id = v_line.administrative_department_id AND d.is_active = true
       )) THEN
      RAISE EXCEPTION 'Owning department is required for each stock transaction line';$replacement$
    ),
    (
      'public.approve_transaction(uuid)'::regprocedure,
      $pattern$IF\s+v_tx_rec\.transaction_type\s+IN\s*\([^)]*\)\s+AND\s+v_rec\.administrative_department_id\s+IS\s+NULL\s+THEN\s+RAISE EXCEPTION 'Owning department is required for each stock transaction line';\s+END IF;$pattern$,
      $replacement$IF v_tx_rec.transaction_type IN ('GRN', 'ISSUE', 'ADJUSTMENT_IN', 'ADJUSTMENT_OUT', 'RETURN_FROM_USAGE', 'RETURN_FROM_CUSTOMER', 'RETURN_TO_SUPPLIER', 'OPENING_BALANCE')
       AND (v_rec.administrative_department_id IS NULL OR NOT EXISTS (
         SELECT 1 FROM public.administrative_departments d
         WHERE d.id = v_rec.administrative_department_id AND d.is_active = true
       )) THEN
      RAISE EXCEPTION 'Owning department is required for each stock transaction line';
    END IF;$replacement$
    )
  ) AS x(fn, pattern, replacement)
  LOOP
    SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid = r.fn::oid;
    SELECT count(*) INTO v_count FROM regexp_matches(v_body, r.pattern, 'g');
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'Expected exactly one owning-department validation clause in %, found %', r.fn, v_count;
    END IF;
    v_new_body := regexp_replace(v_body, r.pattern, r.replacement, 'g');
    v_def := pg_get_functiondef(r.fn::oid);
    v_new_def := replace(v_def, v_body, v_new_body);
    IF v_new_def = v_def THEN
      RAISE EXCEPTION 'Could not reconstruct function definition for %', r.fn;
    END IF;
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
