-- ORSHAP WMS v13.9.58: restrict helper and trigger-function RPC grants.
-- Trigger functions are invoked by PostgreSQL triggers; clients must not call them directly.
BEGIN;

REVOKE ALL ON FUNCTION public.current_user_can_create_warehouse() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_can_create_warehouse() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.enforce_stocktake_line_warehouse_scope() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.enforce_stocktake_warehouse_scope() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.enforce_transaction_line_warehouse_scope() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.enforce_transaction_warehouse_scope() FROM PUBLIC, anon, authenticated;

COMMIT;
