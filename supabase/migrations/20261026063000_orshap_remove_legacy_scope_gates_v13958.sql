-- ORSHAP WMS v13.9.58: remove the final role-vs-user-assignment gates from transfer/return RPCs.
-- Effective access is always decided by current_user_can_access_warehouse().
BEGIN;
DO $patch$
DECLARE r record; v_body text; v_new_body text; v_def text; v_new_def text; v_count integer;
BEGIN
 FOR r IN SELECT * FROM (VALUES
  ('public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text)'::regprocedure,
   $a$IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_src.warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse'; END IF;$a$,
   $b$IF NOT public.current_user_can_access_warehouse(v_src.warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501'; END IF;$b$),
  ('public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text)'::regprocedure,
   $a$IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_shelf.warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the return warehouse'; END IF;$a$,
   $b$IF NOT public.current_user_can_access_warehouse(v_shelf.warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the return warehouse' USING ERRCODE='42501'; END IF;$b$)
 ) AS x(fn,anchor,replacement)
 LOOP
  SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid=r.fn::oid;
  v_count := (length(v_body)-length(replace(v_body,r.anchor,'')))/length(r.anchor);
  IF v_count <> 1 THEN RAISE EXCEPTION 'Expected exactly one patch anchor in %, found %',r.fn,v_count; END IF;
  v_new_body := replace(v_body,r.anchor,r.replacement);
  v_def := pg_get_functiondef(r.fn::oid);
  v_new_def := replace(v_def,v_body,v_new_body);
  IF v_new_def=v_def THEN RAISE EXCEPTION 'Could not reconstruct function definition for %',r.fn; END IF;
  EXECUTE v_new_def;
 END LOOP;
END
$patch$;
COMMIT;
