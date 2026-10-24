-- Item master is location-neutral. Physical location is selected per transaction/stock row.
-- This removes only denormalized default-location metadata; no stock or ledger rows are changed.
DROP TRIGGER IF EXISTS items_sync_default_location_refs ON public.items;
DROP FUNCTION IF EXISTS public.sync_item_default_location_refs();

ALTER TABLE public.items
  DROP CONSTRAINT IF EXISTS items_default_warehouse_id_fkey,
  DROP CONSTRAINT IF EXISTS items_default_zone_id_fkey,
  DROP CONSTRAINT IF EXISTS items_default_section_id_fkey,
  DROP CONSTRAINT IF EXISTS items_default_shelf_id_fkey,
  DROP CONSTRAINT IF EXISTS items_default_storage_area_id_fkey;

DROP INDEX IF EXISTS public.idx_items_default_warehouse_id;
DROP INDEX IF EXISTS public.idx_items_default_zone_id;
DROP INDEX IF EXISTS public.idx_items_default_section_id;
DROP INDEX IF EXISTS public.idx_items_default_shelf_id;
DROP INDEX IF EXISTS public.idx_items_default_storage_area_id;

ALTER TABLE public.items
  DROP COLUMN IF EXISTS default_warehouse_id,
  DROP COLUMN IF EXISTS default_zone_id,
  DROP COLUMN IF EXISTS default_section_id,
  DROP COLUMN IF EXISTS default_shelf_id,
  DROP COLUMN IF EXISTS default_storage_area_id;

DO $verify$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='items'
      AND column_name IN ('default_warehouse_id','default_zone_id','default_section_id','default_shelf_id','default_storage_area_id')
  ) THEN
    RAISE EXCEPTION 'Item default-location columns remain after migration';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.triggers
    WHERE trigger_schema='public' AND event_object_table='items'
      AND trigger_name='items_sync_default_location_refs'
  ) THEN
    RAISE EXCEPTION 'Legacy item default-location trigger remains after migration';
  END IF;
END
$verify$;
