-- ORSHAP WMS v13.9.58: apply configurable role scope at exposed transfer/return RPC boundaries.
-- The central predicate preserves explicit user restrictions and applies role SELECTED/ALL modes.
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
        'public.dispatch_stock_transfer_order_v2(uuid,text,uuid,uuid,jsonb,text)'::regprocedure,
        $a$SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';
  IF NOT FOUND THEN RAISE EXCEPTION 'Active user profile required'; END IF;$a$,
        $b$IF NOT public.current_user_can_access_warehouse(p_source_warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501'; END IF;$b$
      ),
      (
        'public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text)'::regprocedure,
        $a$SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Active user profile required'; END IF;$a$,
        $b$IF NOT public.current_user_can_access_warehouse((SELECT sh.warehouse_id FROM public.shelves sh WHERE sh.id=p_source_shelf_id)) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501'; END IF;$b$
      ),
      (
        'public.dispatch_stock_transfer(uuid,text,uuid,numeric,text,date,uuid,uuid,text)'::regprocedure,
        $a$SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Active user profile required'; END IF;$a$,
        $b$IF NOT public.current_user_can_access_warehouse((SELECT sh.warehouse_id FROM public.shelves sh WHERE sh.id=p_source_shelf_id)) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501'; END IF;$b$
      ),
      (
        'public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text)'::regprocedure,
        $a$SELECT * INTO v_profile FROM public.profiles WHERE id=v_user AND status='ACTIVE';$a$,
        $b$IF NOT public.current_user_can_access_warehouse((SELECT sh.warehouse_id FROM public.shelves sh WHERE sh.id=p_shelf_id)) THEN RAISE EXCEPTION 'User is not assigned to the return warehouse' USING ERRCODE='42501'; END IF;$b$
      ),
      (
        'public.receive_stock_transfer_quantity_at_shelf_v2(uuid,numeric,uuid,boolean,text,uuid)'::regprocedure,
        $a$IF NOT FOUND THEN RAISE EXCEPTION 'Stock transfer line not found'; END IF;$a$,
        $b$IF NOT public.current_user_can_access_warehouse(v_transfer.destination_warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the destination warehouse' USING ERRCODE='42501'; END IF;$b$
      ),
      (
        'public.confirm_stock_transfer_return(uuid)'::regprocedure,
        $a$IF NOT FOUND THEN RAISE EXCEPTION 'Stock transfer line not found'; END IF;$a$,
        $b$IF NOT public.current_user_can_access_warehouse(v_t.source_warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the sending warehouse' USING ERRCODE='42501'; END IF;$b$
      ),
      (
        'public.review_stock_transfer_return_request(uuid,text,text)'::regprocedure,
        $a$IF NOT FOUND THEN RAISE EXCEPTION 'Stock transfer line not found'; END IF;$a$,
        $b$IF NOT public.current_user_can_access_warehouse(v_t.source_warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the sending warehouse' USING ERRCODE='42501'; END IF;$b$
      )
    ) AS x(fn, anchor, guard)
  LOOP
    SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid=r.fn::oid;
    v_count := (length(v_body)-length(replace(v_body,r.anchor,'')))/length(r.anchor);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'Expected exactly one patch anchor in %, found %', r.fn, v_count;
    END IF;
    v_new_body := replace(v_body,r.anchor,r.anchor || E'\n  ' || r.guard);
    v_def := pg_get_functiondef(r.fn::oid);
    v_new_def := replace(v_def,v_body,v_new_body);
    IF v_new_def = v_def THEN
      RAISE EXCEPTION 'Could not reconstruct function definition for %', r.fn;
    END IF;
    EXECUTE v_new_def;
  END LOOP;
END
$patch$;
COMMIT;
