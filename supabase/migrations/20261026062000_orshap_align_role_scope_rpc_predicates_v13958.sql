-- ORSHAP WMS v13.9.58: make role-selected/all warehouse scope consistent across RPCs.
-- Central predicate remains authoritative; user-level assignment still intersects role scope.
-- Exact patches are validated against the live definitions and fail closed if anchors drift.
BEGIN;
DO $patch$
DECLARE r record; v_body text; v_new_body text; v_def text; v_new_def text; v_count integer;
BEGIN
 FOR r IN SELECT * FROM (VALUES
  ('public.dispatch_stock_transfer(uuid,text,uuid,numeric,text,date,uuid,uuid,text)'::regprocedure,
   $a$IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER')
    AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT (v_src.warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN
   RAISE EXCEPTION 'User is not assigned to the source warehouse';
 END IF;$a$,
   $b$IF NOT public.current_user_can_access_warehouse(v_src.warehouse_id) THEN
   RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501';
 END IF;$b$),
  ('public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text)'::regprocedure,
   $a$IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(v_existing.source_warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501'; END IF;$a$,
   $b$IF NOT public.current_user_can_access_warehouse(v_existing.source_warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501'; END IF;$b$),
  ('public.dispatch_stock_transfer_order_v2(uuid,text,uuid,uuid,jsonb,text)'::regprocedure,
   $a$IF COALESCE(v_profile.role,'') NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0 OR NOT(p_source_warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse'; END IF;$a$,
   $b$IF NOT public.current_user_can_access_warehouse(p_source_warehouse_id) THEN RAISE EXCEPTION 'User is not assigned to the source warehouse' USING ERRCODE='42501'; END IF;$b$),
  ('public.receive_stock_transfer_quantity_at_shelf_v2(uuid,numeric,uuid,boolean,text,uuid)'::regprocedure,
   $a$IF COALESCE(v_profile.role,'') NOT IN ('SUPER_ADMIN','ADMIN','MANAGER')
     AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0
          OR NOT (v_transfer.destination_warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN
    RAISE EXCEPTION 'User is not assigned to the destination warehouse' USING ERRCODE='42501';
  END IF;$a$,
   $b$IF NOT public.current_user_can_access_warehouse(v_transfer.destination_warehouse_id) THEN
    RAISE EXCEPTION 'User is not assigned to the destination warehouse' USING ERRCODE='42501';
  END IF;$b$),
  ('public.create_stock_return_request(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text)'::regprocedure,
   $a$sh.warehouse_id=v_existing.warehouse_id AND (v_profile.role IN ('SUPER_ADMIN','ADMIN','MANAGER') OR (cardinality(COALESCE(v_profile.assigned_warehouse_ids, ARRAY[]::uuid[])) > 0 AND sh.warehouse_id=ANY(v_profile.assigned_warehouse_ids)))$a$,
   $b$sh.warehouse_id=v_existing.warehouse_id AND public.current_user_can_access_warehouse(sh.warehouse_id)$b$),
  ('public.get_stock_summary_by_storage_area(timestamptz,timestamptz,uuid,uuid,uuid)'::regprocedure,
   $a$IF cardinality(v_assigned)>0 THEN
    IF p_warehouse_id IS NULL OR NOT public.current_user_can_access_warehouse(p_warehouse_id) THEN
      RAISE EXCEPTION 'Select a warehouse assigned to your account';
    END IF;
  ELSE
    IF v_role NOT IN ('SUPER_ADMIN','ADMIN') THEN
      RAISE EXCEPTION 'No warehouse is assigned to this account';
    END IF;
    IF p_warehouse_id IS NOT NULL AND NOT public.current_user_can_access_warehouse(p_warehouse_id) THEN
      RAISE EXCEPTION 'Report warehouse is outside the current user assigned scope';
    END IF;
  END IF;$a$,
   $b$IF p_warehouse_id IS NOT NULL THEN
    IF NOT public.current_user_can_access_warehouse(p_warehouse_id) THEN
      RAISE EXCEPTION 'Report warehouse is outside the current user assigned scope' USING ERRCODE='42501';
    END IF;
  ELSIF NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE public.current_user_can_access_warehouse(w.id)) THEN
    RAISE EXCEPTION 'No warehouse is accessible to this account' USING ERRCODE='42501';
  END IF;$b$),
  ('public.get_stock_summary_by_storage_area(timestamptz,timestamptz,uuid,uuid,uuid)'::regprocedure,
   $a$WHERE (p_warehouse_id IS NULL OR il.warehouse_id=p_warehouse_id)
      AND (p_storage_area_id IS NULL OR il.storage_area_id=p_storage_area_id)$a$,
   $b$WHERE (p_warehouse_id IS NULL OR il.warehouse_id=p_warehouse_id)
      AND public.current_user_can_access_warehouse(il.warehouse_id)
      AND (p_storage_area_id IS NULL OR il.storage_area_id=p_storage_area_id)$b$),
  ('public.get_stock_summary_by_storage_area(timestamptz,timestamptz,uuid,uuid,uuid)'::regprocedure,
   $a$WHERE (p_warehouse_id IS NULL OR sh.warehouse_id=p_warehouse_id)
      AND (p_storage_area_id IS NULL OR s.storage_area_id=p_storage_area_id)$a$,
   $b$WHERE (p_warehouse_id IS NULL OR sh.warehouse_id=p_warehouse_id)
      AND public.current_user_can_access_warehouse(sh.warehouse_id)
      AND (p_storage_area_id IS NULL OR s.storage_area_id=p_storage_area_id)$b$)
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

 SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid='public.review_stock_transfer_return_request(uuid,text,text)'::regprocedure;
 SELECT count(*) INTO v_count FROM regexp_matches(v_body,$rx$IF COALESCE\(v_profile\.role, ''\) NOT IN \('SUPER_ADMIN','ADMIN','MANAGER'\)\s+AND \(cardinality\(COALESCE\(v_profile\.assigned_warehouse_ids, ARRAY\[\]::uuid\[\]\)\) = 0\s+OR NOT \(v_t\.source_warehouse_id = ANY\(v_profile\.assigned_warehouse_ids\)\)\) THEN\s+RAISE EXCEPTION 'User is not assigned to the sending warehouse';\s+END IF;$rx$,'g');
 IF v_count<>1 THEN RAISE EXCEPTION 'Expected one legacy return-review assignment gate, found %',v_count; END IF;
 v_new_body:=regexp_replace(v_body,$rx$IF COALESCE\(v_profile\.role, ''\) NOT IN \('SUPER_ADMIN','ADMIN','MANAGER'\)\s+AND \(cardinality\(COALESCE\(v_profile\.assigned_warehouse_ids, ARRAY\[\]::uuid\[\]\)\) = 0\s+OR NOT \(v_t\.source_warehouse_id = ANY\(v_profile\.assigned_warehouse_ids\)\)\) THEN\s+RAISE EXCEPTION 'User is not assigned to the sending warehouse';\s+END IF;$rx$,$rep$IF NOT public.current_user_can_access_warehouse(v_t.source_warehouse_id) THEN
    RAISE EXCEPTION 'User is not assigned to the sending warehouse' USING ERRCODE='42501';
  END IF;$rep$);
 v_def:=pg_get_functiondef('public.review_stock_transfer_return_request(uuid,text,text)'::regprocedure);
 v_new_def:=replace(v_def,v_body,v_new_body);
 IF v_new_def=v_def THEN RAISE EXCEPTION 'Could not reconstruct return-review function'; END IF;
 EXECUTE v_new_def;
END
$patch$;
COMMIT;
