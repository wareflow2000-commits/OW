-- ORSHAP WMS v13.9.58
-- The canonical model is storage_areas.warehouse_id. This legacy join table is empty,
-- denied to API roles, has no inbound foreign keys, and is not referenced by public functions.
-- Drop without CASCADE so any undiscovered database dependency aborts safely.
DROP TABLE IF EXISTS public.warehouse_storage_areas;
