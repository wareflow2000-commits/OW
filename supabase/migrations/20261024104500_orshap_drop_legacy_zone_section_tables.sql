-- ORSHAP WMS v13.9.58
-- Remove obsolete zones/sections entities and the storage-area legacy bridge.
-- Historical zone_id/section_id values remain as non-relational snapshots until all
-- downstream reporting/ledger functions are migrated. No stock or ledger quantities change.
DO $cleanup$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT conrelid::regclass AS tbl, conname
    FROM pg_constraint
    WHERE contype='f'
      AND confrelid IN (to_regclass('public.zones'),to_regclass('public.sections'))
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',r.tbl,r.conname);
  END LOOP;

  ALTER TABLE public.shelves DROP CONSTRAINT IF EXISTS shelves_zone_id_code_key;
  ALTER TABLE public.sections DROP CONSTRAINT IF EXISTS sections_zone_id_code_key;

  DROP TABLE IF EXISTS public.legacy_section_classification;
  DROP TABLE IF EXISTS public.sections;
  DROP TABLE IF EXISTS public.zones;

  ALTER TABLE public.storage_areas
    DROP CONSTRAINT IF EXISTS storage_areas_legacy_zone_id_fkey,
    DROP CONSTRAINT IF EXISTS storage_areas_legacy_zone_id_key,
    DROP COLUMN IF EXISTS legacy_zone_id;
END
$cleanup$;
