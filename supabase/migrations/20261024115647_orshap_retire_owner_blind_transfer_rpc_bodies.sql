-- ORSHAP WMS v13.9.58
-- Retire old destination-warehouse transfer RPC bodies. Client execution was revoked earlier;
-- the stubs also prevent service-role callers from reaching owner-blind stock logic.
BEGIN;
CREATE OR REPLACE FUNCTION public.dispatch_stock_transfer_with_destination_warehouse(p_transfer_id uuid, p_reference_no text, p_item_id uuid, p_quantity numeric, p_batch_no text DEFAULT ''::text, p_expiry_date date DEFAULT NULL::date, p_source_shelf_id uuid DEFAULT NULL::uuid, p_destination_shelf_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text, p_destination_warehouse_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
BEGIN
  RAISE EXCEPTION 'Legacy destination-warehouse transfer RPC is retired; use owner-aware dispatch_stock_transfer';
END;
$function$
;

CREATE OR REPLACE FUNCTION public.dispatch_stock_transfer_with_destination_warehouse(p_transfer_id uuid, p_reference_no text, p_item_id uuid, p_quantity numeric, p_batch_no text, p_expiry_date date, p_source_shelf_id uuid, p_destination_shelf_id uuid, p_notes text, p_destination_warehouse_id uuid, p_destination_storage_area_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
BEGIN
  RAISE EXCEPTION 'Legacy destination-warehouse transfer RPC is retired; use owner-aware dispatch_stock_transfer';
END;
$function$
;
COMMIT;