-- Guard return receipt finalization so the RPC cannot report RECEIVED
-- unless the accepted review state was actually transitioned.
CREATE OR REPLACE FUNCTION public.confirm_stock_transfer_return_v2(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_result jsonb;
  v_rows integer := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'Active authenticated user required';
  END IF;

  -- The underlying routine performs permission, warehouse-scope, row-lock,
  -- stock-posting, and ledger checks. Keep both steps in this transaction.
  v_result := public.confirm_stock_transfer_return(p_transfer_id);

  UPDATE public.stock_transfers
     SET return_review_status = 'RECEIVED',
         updated_at = now()
   WHERE id = p_transfer_id
     AND return_review_status = 'ACCEPTED';

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    -- Roll back stock and ledger work rather than returning false success.
    RAISE EXCEPTION 'Return receipt review state could not be finalized';
  END IF;

  RETURN v_result || jsonb_build_object('return_review_status', 'RECEIVED');
END;
$function$;
