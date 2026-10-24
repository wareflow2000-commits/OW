-- ORSHAP WMS v13.9.58
-- Physical shelf location is authoritative through storage_area_id; legacy zone/section
-- columns on shelves are orphaned and no longer used by the UI or current stock model.
DO $migration$
DECLARE v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.shelves sh
  WHERE sh.storage_area_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.storage_areas a WHERE a.id=sh.storage_area_id AND a.warehouse_id=sh.warehouse_id);
  IF v_bad>0 THEN
    RAISE EXCEPTION 'Cannot remove shelf legacy location fields: % shelves have invalid storage_area_id',v_bad;
  END IF;
END;
$migration$;

DROP TRIGGER IF EXISTS shelves_sync_storage_area_refs ON public.shelves;
CREATE TRIGGER shelves_sync_storage_area_refs
AFTER INSERT OR UPDATE OF storage_area_id ON public.shelves
FOR EACH ROW EXECUTE FUNCTION public.sync_shelf_storage_area_refs();

ALTER TABLE public.shelves
  DROP COLUMN IF EXISTS zone_id,
  DROP COLUMN IF EXISTS section_id;
