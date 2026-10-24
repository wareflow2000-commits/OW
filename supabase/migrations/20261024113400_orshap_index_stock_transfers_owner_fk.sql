-- ORSHAP WMS v13.9.58
-- Cover the administrative-department FK on stock_transfers for joins and FK maintenance.
BEGIN;
CREATE INDEX IF NOT EXISTS idx_stock_transfers_administrative_department_id
  ON public.stock_transfers (administrative_department_id);
COMMIT;