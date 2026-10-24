-- ORSHAP WMS v13.9.58
-- Retire direct receipt RPCs without an idempotency operation ID. The current UI
-- uses the six-argument v2 endpoint; the legacy one-shot receive_stock_transfer
-- wrapper remains available for compatibility and calls its internal routines.
REVOKE ALL ON FUNCTION public.receive_stock_transfer_quantity(uuid,numeric,boolean,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.receive_stock_transfer_quantity_at_shelf(uuid,numeric,uuid,boolean,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.receive_stock_transfer_quantity_at_shelf_v2(uuid,numeric,uuid,boolean,text)
  FROM PUBLIC, anon, authenticated;
