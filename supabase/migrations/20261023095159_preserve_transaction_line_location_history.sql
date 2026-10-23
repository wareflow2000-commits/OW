-- ORSHAP WMS v13.9.58
-- Preserve posted transaction-line location as historical evidence.
-- A shelf move may update current stock location, but must not rewrite posted lines.
CREATE OR REPLACE FUNCTION public.sync_shelf_storage_area_refs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_area_warehouse_id uuid;
BEGIN
  IF NEW.storage_area_id IS NULL THEN
    RAISE EXCEPTION 'Shelf must belong to a storage area';
  END IF;

  SELECT warehouse_id
    INTO v_area_warehouse_id
  FROM public.storage_areas
  WHERE id = NEW.storage_area_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shelf storage area does not exist';
  END IF;

  IF NEW.warehouse_id IS DISTINCT FROM v_area_warehouse_id THEN
    RAISE EXCEPTION 'Shelf warehouse does not match its storage area';
  END IF;

  -- Current on-hand stock follows a shelf move.
  -- Posted transaction lines are historical evidence and must not be rewritten.
  UPDATE public.stock
     SET storage_area_id = NEW.storage_area_id
   WHERE shelf_id = NEW.id
     AND storage_area_id IS DISTINCT FROM NEW.storage_area_id;

  RETURN NEW;
END;
$function$;
