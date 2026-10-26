-- ORSHAP WMS v13.9.58: close remaining RPC gaps in configurable warehouse scope.
-- Replaces legacy role-based bypasses with the central role+user scope predicate.
-- Tested in a transaction and rolled back before applying this migration.
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
  FOR r IN
    SELECT * FROM (VALUES
      (
        'public.close_stocktake_session_direct(uuid)'::regprocedure,
        $a$IF v_role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER')
     AND NOT (v_s.warehouse_id = ANY(v_assigned)) THEN
    RAISE EXCEPTION 'You are not assigned to this stocktake warehouse';
  END IF;$a$,
        $b$IF NOT public.current_user_can_access_warehouse(v_s.warehouse_id) THEN
    RAISE EXCEPTION 'You are not assigned to this stocktake warehouse' USING ERRCODE='42501';
  END IF;$b$
      ),
      (
        'public.populate_stocktake_session_lines(uuid)'::regprocedure,
        $a$SELECT assigned_warehouse_ids INTO v_assigned FROM public.profiles WHERE id=v_user_id;
  IF NOT public.current_user_is_manager()
     AND NOT (v_session.warehouse_id=ANY(COALESCE(v_assigned,ARRAY[]::uuid[]))) THEN
    RAISE EXCEPTION 'You cannot populate a session outside your assigned warehouses';
  END IF;$a$,
        $b$IF NOT public.current_user_can_access_warehouse(v_session.warehouse_id) THEN
    RAISE EXCEPTION 'You cannot populate a session outside your assigned warehouses' USING ERRCODE='42501';
  END IF;$b$
      ),
      (
        'public.create_stock_return_request(uuid,text,text,uuid,numeric,text,date,uuid,text,text,text)'::regprocedure,
        $a$IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER')
       AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids, ARRAY[]::uuid[])) = 0
            OR NOT (v_shelf.warehouse_id = ANY(v_profile.assigned_warehouse_ids))) THEN
      RAISE EXCEPTION 'User is not assigned to the return warehouse';
    END IF;$a$,
        $b$IF NOT public.current_user_can_access_warehouse(v_shelf.warehouse_id) THEN
      RAISE EXCEPTION 'User is not assigned to the return warehouse' USING ERRCODE='42501';
    END IF;$b$
      ),
      (
        'public.create_opening_balance_vouchers(jsonb)'::regprocedure,
        $a$IF v_warehouse IS NULL OR NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id=v_warehouse) THEN
      RAISE EXCEPTION 'A valid warehouse is required for every opening-balance group';
    END IF;$a$,
        $b$IF v_warehouse IS NULL OR NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id=v_warehouse) THEN
      RAISE EXCEPTION 'A valid warehouse is required for every opening-balance group';
    END IF;
    IF NOT public.current_user_can_access_warehouse(v_warehouse) THEN
      RAISE EXCEPTION 'Opening-balance warehouse is outside the current user scope' USING ERRCODE='42501';
    END IF;$b$
      ),
      (
        'public.reject_stock_transfer_order(uuid,text)'::regprocedure,
        $a$v_total := v_total + 1;$a$,
        $b$v_total := v_total + 1;
    IF NOT public.current_user_can_access_warehouse(v_line.destination_warehouse_id) THEN
      RAISE EXCEPTION 'Transfer destination is outside the current user scope' USING ERRCODE='42501';
    END IF;$b$
      )
    ) AS x(fn, anchor, replacement)
  LOOP
    SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid = r.fn::oid;
    v_count := (length(v_body) - length(replace(v_body, r.anchor, ''))) / length(r.anchor);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'Expected exactly one patch anchor in %, found %', r.fn, v_count;
    END IF;
    v_new_body := replace(v_body, r.anchor, r.replacement);
    v_def := pg_get_functiondef(r.fn::oid);
    v_new_def := replace(v_def, v_body, v_new_body);
    IF v_new_def = v_def THEN
      RAISE EXCEPTION 'Could not reconstruct function definition for %', r.fn;
    END IF;
    EXECUTE v_new_def;
  END LOOP;
END
$patch$;
COMMIT;
