-- ORSHAP WMS v13.9.58
-- Retire the legacy owner-blind stock movement RPC. Current UI paths use
-- transaction/transfer/return workflows that enforce the owning department.
CREATE OR REPLACE FUNCTION public.process_stock_movement(
  p_movement_type text,
  p_reference_no text,
  p_item_id uuid,
  p_quantity numeric,
  p_batch_no text DEFAULT ''::text,
  p_expiry_date date DEFAULT NULL::date,
  p_source_shelf_id uuid DEFAULT NULL::uuid,
  p_destination_shelf_id uuid DEFAULT NULL::uuid,
  p_supplier text DEFAULT NULL::text,
  p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth','pg_temp'
AS $function$
BEGIN
  RAISE EXCEPTION 'Legacy owner-blind stock movement RPC is retired; use the owner-aware transaction, transfer, or return workflow';
END;
$function$;

REVOKE ALL ON FUNCTION public.process_stock_movement(text,text,uuid,numeric,text,date,uuid,uuid,text,text)
  FROM PUBLIC,anon,authenticated;
