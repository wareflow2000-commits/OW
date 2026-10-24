-- ORSHAP WMS v13.9.58
-- Remove the zone-to-storage-area fallback from transfer, return and movement procedures.
-- This migration does not post stock movements or change existing inventory rows.
DO $audit$
DECLARE r record; v_def text; v_new text;
BEGIN
  FOR r IN
    SELECT p.oid,p.proname,pg_get_function_identity_arguments(p.oid) args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname IN ('confirm_stock_transfer_return','dispatch_stock_transfer','dispatch_stock_transfer_with_destination_warehouse','process_stock_movement','receive_stock_transfer_quantity_at_shelf_v2','reject_stock_transfer_receipt')
      AND p.prosrc ILIKE '%legacy_zone_id%'
  LOOP
    v_def:=pg_get_functiondef(r.oid); v_new:=v_def;
    v_new:=regexp_replace(v_new,
      'COALESCE\s*\(\s*([a-z_]+)\.storage_area_id\s*,\s*\(SELECT\s+id\s+FROM\s+public\.storage_areas\s+WHERE\s+warehouse_id\s*=\s*[a-z_]+\.warehouse_id\s+AND\s+legacy_zone_id\s*=\s*[a-z_]+\.zone_id\s+LIMIT\s+1\)\s*\)',
      '\1.storage_area_id','gi');
    v_new:=regexp_replace(v_new,
      'IF\s+v_(source|dest)_area\s+IS NULL THEN\s+SELECT\s+id\s+INTO\s+v_\1_area\s+FROM\s+public\.storage_areas\s+WHERE\s+warehouse_id\s*=\s*v_\1\.warehouse_id\s+AND\s+legacy_zone_id\s*=\s*v_\1\.zone_id\s+LIMIT\s+1;\s+END IF;',
      'IF v_\1_area IS NULL THEN RAISE EXCEPTION ''Shelf must belong to a valid storage area''; END IF;',
      'gi');
    IF v_new=v_def OR v_new ILIKE '%legacy_zone_id%' THEN
      RAISE EXCEPTION 'Legacy-zone replacement incomplete for public.%(%)',r.proname,r.args;
    END IF;
    EXECUTE v_new;
  END LOOP;
END
$audit$;
