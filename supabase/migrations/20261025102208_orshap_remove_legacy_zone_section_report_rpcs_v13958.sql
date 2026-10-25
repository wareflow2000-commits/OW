-- ORSHAP WMS v13.9.58
-- The application uses get_stock_summary_by_storage_area exclusively.
-- Retire obsolete report RPCs whose public signature still exposes zones/sections.
-- Historical transaction/ledger data is untouched. DROP fails safely if an actual
-- database object depends on either function; review that dependency before retrying.
BEGIN;
DROP FUNCTION IF EXISTS public.get_stock_summary_report(timestamptz, timestamptz, uuid, uuid, uuid);
DROP FUNCTION IF EXISTS public.get_stock_summary_report_internal(timestamptz, timestamptz, uuid, uuid, uuid);
COMMIT;
