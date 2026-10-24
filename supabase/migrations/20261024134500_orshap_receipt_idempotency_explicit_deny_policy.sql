-- Defense-in-depth: explicitly deny all direct client row access to receipt idempotency records.
DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy p
    WHERE p.polrelid='public.stock_transfer_receipt_idempotency'::regclass
      AND p.polname='receipt_idempotency_deny_client_access'
  ) THEN
    CREATE POLICY receipt_idempotency_deny_client_access
      ON public.stock_transfer_receipt_idempotency
      FOR ALL TO anon, authenticated
      USING (false)
      WITH CHECK (false);
  END IF;
END;
$migration$;
