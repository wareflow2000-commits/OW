-- ORSHAP WMS v13.9.58
-- Cover the user FK on receipt idempotency records to keep user deletion/updates
-- and user-scoped audit queries from requiring a full table scan.
CREATE INDEX IF NOT EXISTS idx_stock_transfer_receipt_idempotency_user_id
  ON public.stock_transfer_receipt_idempotency (user_id);
