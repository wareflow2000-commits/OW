-- ORSHAP WMS v13.9.58
-- Retire one-shot receive wrappers that can call non-operation-ID receipt routines
-- from SECURITY DEFINER context. The supported client receipt path is the
-- six-argument receive_stock_transfer_quantity_at_shelf_v2 RPC.
REVOKE ALL ON FUNCTION public.receive_stock_transfer(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.receive_stock_transfer_order(uuid)
  FROM PUBLIC, anon, authenticated;
