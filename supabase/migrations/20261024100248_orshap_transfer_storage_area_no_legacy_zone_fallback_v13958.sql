CREATE OR REPLACE FUNCTION public.sync_stock_transfer_storage_areas()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE v_source_area uuid; v_destination_area uuid; v_source_warehouse uuid; v_destination_warehouse uuid;
BEGIN
  SELECT sh.storage_area_id,sh.warehouse_id INTO v_source_area,v_source_warehouse FROM public.shelves sh WHERE sh.id=NEW.source_shelf_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer source shelf does not exist'; END IF;
  IF v_source_warehouse IS DISTINCT FROM NEW.source_warehouse_id THEN RAISE EXCEPTION 'Transfer source shelf must belong to the source warehouse'; END IF;
  IF v_source_area IS NULL THEN RAISE EXCEPTION 'Transfer source shelf must belong to a storage area'; END IF;
  IF NEW.source_storage_area_id IS NULL THEN NEW.source_storage_area_id:=v_source_area;
  ELSIF NEW.source_storage_area_id IS DISTINCT FROM v_source_area THEN RAISE EXCEPTION 'Source shelf must belong to the selected source storage area'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.storage_areas sa WHERE sa.id=NEW.source_storage_area_id AND sa.warehouse_id=NEW.source_warehouse_id) THEN RAISE EXCEPTION 'Source storage area must belong to the source warehouse'; END IF;
  IF NEW.destination_shelf_id IS NOT NULL THEN
    SELECT sh.storage_area_id,sh.warehouse_id INTO v_destination_area,v_destination_warehouse FROM public.shelves sh WHERE sh.id=NEW.destination_shelf_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Transfer destination shelf does not exist'; END IF;
    IF v_destination_warehouse IS DISTINCT FROM NEW.destination_warehouse_id THEN RAISE EXCEPTION 'Transfer destination shelf must belong to the destination warehouse'; END IF;
    IF v_destination_area IS NULL THEN RAISE EXCEPTION 'Transfer destination shelf must belong to a storage area'; END IF;
    IF NEW.destination_storage_area_id IS NULL THEN NEW.destination_storage_area_id:=v_destination_area;
    ELSIF NEW.destination_storage_area_id IS DISTINCT FROM v_destination_area THEN RAISE EXCEPTION 'Destination shelf must belong to the selected destination storage area'; END IF;
  END IF;
  IF NEW.destination_storage_area_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.storage_areas sa WHERE sa.id=NEW.destination_storage_area_id AND sa.warehouse_id=NEW.destination_warehouse_id) THEN RAISE EXCEPTION 'Destination storage area must belong to the destination warehouse'; END IF;
  RETURN NEW;
END;
$function$;
