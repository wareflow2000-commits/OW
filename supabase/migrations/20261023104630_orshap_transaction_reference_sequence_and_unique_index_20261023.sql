-- ORSHAP WMS: globally unique, database-generated transaction references.
-- Existing references are preserved; this migration only adds uniqueness enforcement and a generator.
CREATE SEQUENCE IF NOT EXISTS public.transaction_reference_seq
  AS bigint START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;

CREATE UNIQUE INDEX IF NOT EXISTS transactions_reference_no_normalized_uidx
  ON public.transactions (lower(btrim(reference_no)))
  WHERE nullif(btrim(reference_no), '') IS NOT NULL;

CREATE OR REPLACE FUNCTION public.next_transaction_reference()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_role text;
  v_status text;
  v_seq bigint;
  v_ref text;
BEGIN
  IF v_user IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'Active authenticated user required';
  END IF;

  SELECT p.role, p.status INTO v_role, v_status
  FROM public.profiles p WHERE p.id = v_user;

  IF NOT FOUND OR v_status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'Active user profile required';
  END IF;

  IF NOT (
    public.current_user_has_permission('action:transaction:grn:create')
    OR public.current_user_has_permission('action:transaction:issue:create')
    OR public.current_user_has_permission('action:transaction:adjustment:create')
    OR public.current_user_has_permission('action:stock_transfer:create')
  ) THEN
    RAISE EXCEPTION 'Permission denied to generate a transaction reference';
  END IF;

  v_seq := nextval('public.transaction_reference_seq'::regclass);
  v_ref := 'OR-' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDD') || '-' || lpad(v_seq::text, 8, '0');
  RETURN v_ref;
END;
$function$;

REVOKE ALL ON FUNCTION public.next_transaction_reference() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.next_transaction_reference() FROM anon;
GRANT EXECUTE ON FUNCTION public.next_transaction_reference() TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.transaction_reference_seq TO authenticated;
