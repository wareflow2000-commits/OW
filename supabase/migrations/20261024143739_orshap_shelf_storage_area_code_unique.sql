-- ORSHAP WMS v13.9.58
-- Canonical uniqueness: shelf codes must be unique within a storage area.
-- Preflight confirmed no duplicate (storage_area_id, code) pairs.
CREATE UNIQUE INDEX IF NOT EXISTS shelves_storage_area_id_code_key
  ON public.shelves (storage_area_id, code)
  WHERE storage_area_id IS NOT NULL;
