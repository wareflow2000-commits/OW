-- Stop recreating/synchronizing storage areas from the retired zones table.
-- This is intentionally non-destructive: legacy tables/columns remain until all
-- transaction, transfer, stocktake, reporting and historical-ledger dependencies
-- have been replaced and validated.
DROP TRIGGER IF EXISTS zones_sync_storage_area ON public.zones;
DROP FUNCTION IF EXISTS public.sync_zone_storage_area();

-- Defensive verification: no trigger on zones may call the removed sync routine.
DO $verify$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'zones'
      AND NOT t.tgisinternal
      AND pg_get_triggerdef(t.oid) ILIKE '%sync_zone_storage_area%'
  ) THEN
    RAISE EXCEPTION 'Legacy zone-to-storage-area sync trigger still exists';
  END IF;
END
$verify$;
