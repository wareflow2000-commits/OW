-- The reviewed v2 wrapper is the only client-facing return-receipt path.
-- Keep the underlying implementation callable by its owner for the wrapper, but not directly by API roles.
REVOKE ALL ON FUNCTION public.confirm_stock_transfer_return(uuid) FROM PUBLIC, anon, authenticated;
