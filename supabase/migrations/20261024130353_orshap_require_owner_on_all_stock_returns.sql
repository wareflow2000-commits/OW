-- ORSHAP WMS v13.9.58
-- Every stock-return line must post to a valid owning department.
-- Enforce the same invariant at request creation and approval, not only in the UI.
DO $migration$
DECLARE
  v_def text;
  v_sig regprocedure;
  v_old text;
  v_new text;
BEGIN
  v_sig := 'public.create_transaction_with_lines(uuid,jsonb,jsonb)'::regprocedure;
  v_def := pg_get_functiondef(v_sig);
  v_old := E'IF v_type IN (''GRN'',''ISSUE'',''ADJUSTMENT_IN'',''ADJUSTMENT_OUT'')\n       AND v_line.administrative_department_id IS NULL THEN';
  v_new := E'IF v_type IN (''GRN'',''ISSUE'',''ADJUSTMENT_IN'',''ADJUSTMENT_OUT'',''RETURN_FROM_USAGE'',''RETURN_FROM_CUSTOMER'',''RETURN_TO_SUPPLIER'')\n       AND v_line.administrative_department_id IS NULL THEN';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transaction creation owner guard not found'; END IF;
  v_def := replace(v_def,v_old,v_new);
  IF position(v_new IN v_def)=0 THEN RAISE EXCEPTION 'Transaction creation owner guard verification failed'; END IF;
  EXECUTE v_def;

  v_sig := 'public.approve_transaction(uuid)'::regprocedure;
  v_def := pg_get_functiondef(v_sig);
  v_old := 'IF v_tx_rec.transaction_type IN (''GRN'', ''ISSUE'', ''ADJUSTMENT_IN'', ''ADJUSTMENT_OUT'') AND v_rec.administrative_department_id IS NULL THEN';
  v_new := 'IF v_tx_rec.transaction_type IN (''GRN'', ''ISSUE'', ''ADJUSTMENT_IN'', ''ADJUSTMENT_OUT'', ''RETURN_FROM_USAGE'', ''RETURN_FROM_CUSTOMER'', ''RETURN_TO_SUPPLIER'') AND v_rec.administrative_department_id IS NULL THEN';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Approval owner guard not found'; END IF;
  v_def := replace(v_def,v_old,v_new);
  IF position(v_new IN v_def)=0 THEN RAISE EXCEPTION 'Approval owner guard verification failed'; END IF;
  EXECUTE v_def;

  v_sig := 'public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text)'::regprocedure;
  v_def := pg_get_functiondef(v_sig);
  v_old := 'IF v_owner IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.administrative_departments d WHERE d.id=v_owner) THEN RAISE EXCEPTION ''Owner department not found''; END IF;';
  v_new := 'IF v_owner IS NULL THEN RAISE EXCEPTION ''Owner department is required for every stock return''; END IF; IF NOT EXISTS (SELECT 1 FROM public.administrative_departments d WHERE d.id=v_owner AND d.is_active=true) THEN RAISE EXCEPTION ''Owner department not found or inactive''; END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Return request owner validation not found'; END IF;
  v_def := replace(v_def,v_old,v_new);
  IF position(v_new IN v_def)=0 THEN RAISE EXCEPTION 'Return request owner validation verification failed'; END IF;
  EXECUTE v_def;
END;
$migration$;
