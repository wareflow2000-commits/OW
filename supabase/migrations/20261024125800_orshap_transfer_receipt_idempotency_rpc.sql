-- ORSHAP WMS v13.9.58
-- Idempotent physical transfer receipt RPC. The caller must persist and reuse
-- p_operation_id until the request succeeds; same key + same payload replays result.
CREATE TABLE IF NOT EXISTS public.stock_transfer_receipt_idempotency (
  transfer_id uuid NOT NULL REFERENCES public.stock_transfers(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  payload_hash text NOT NULL,
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stock_transfer_receipt_idempotency_pk PRIMARY KEY (transfer_id, operation_id),
  CONSTRAINT stock_transfer_receipt_idempotency_hash_chk CHECK (payload_hash ~ '^[0-9a-f]{32}$')
);
ALTER TABLE public.stock_transfer_receipt_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.stock_transfer_receipt_idempotency FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.receive_stock_transfer_quantity_at_shelf_v2(
  p_transfer_id uuid,
  p_received_quantity numeric,
  p_destination_shelf_id uuid,
  p_return_remaining boolean,
  p_reason text,
  p_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_profile public.profiles%ROWTYPE;
  v_transfer public.stock_transfers%ROWTYPE;
  v_hash text;
  v_existing public.stock_transfer_receipt_idempotency%ROWTYPE;
  v_result jsonb;
BEGIN
  IF v_user IS NULL OR NOT (SELECT public.current_user_is_active()) THEN
    RAISE EXCEPTION 'An active authenticated user is required' USING ERRCODE='42501';
  END IF;
  IF NOT (SELECT public.current_user_has_permission('action:stock_transfer:receive')) THEN
    RAISE EXCEPTION 'Permission denied to receive stock transfers' USING ERRCODE='42501';
  END IF;
  IF p_operation_id IS NULL THEN
    RAISE EXCEPTION 'A stable receipt operation ID is required';
  END IF;
  IF p_transfer_id IS NULL OR p_received_quantity IS NULL
     OR p_received_quantity < 0
     OR p_received_quantity::text IN ('NaN','Infinity','-Infinity') THEN
    RAISE EXCEPTION 'Invalid receipt payload';
  END IF;

  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id=v_user AND status='ACTIVE';
  IF NOT FOUND THEN RAISE EXCEPTION 'Active user profile required' USING ERRCODE='42501'; END IF;

  SELECT * INTO v_transfer
  FROM public.stock_transfers
  WHERE id=p_transfer_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stock transfer line not found'; END IF;

  IF COALESCE(v_profile.role,'') NOT IN ('SUPER_ADMIN','ADMIN','MANAGER')
     AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids,ARRAY[]::uuid[]))=0
          OR NOT (v_transfer.destination_warehouse_id=ANY(v_profile.assigned_warehouse_ids))) THEN
    RAISE EXCEPTION 'User is not assigned to the destination warehouse' USING ERRCODE='42501';
  END IF;

  v_hash := md5(jsonb_build_object(
    'user_id',v_user,
    'transfer_id',p_transfer_id,
    'received_quantity',p_received_quantity,
    'destination_shelf_id',p_destination_shelf_id,
    'return_remaining',COALESCE(p_return_remaining,false),
    'reason',NULLIF(btrim(COALESCE(p_reason,'')),'')
  )::text);

  SELECT * INTO v_existing
  FROM public.stock_transfer_receipt_idempotency
  WHERE transfer_id=p_transfer_id AND operation_id=p_operation_id;

  IF FOUND THEN
    IF v_existing.user_id IS DISTINCT FROM v_user
       OR v_existing.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'Idempotency conflict: receipt operation ID was reused with a different payload'
        USING ERRCODE='23505';
    END IF;
    RETURN v_existing.result || jsonb_build_object('already_processed',true);
  END IF;

  v_result := public.receive_stock_transfer_quantity_at_shelf_v2(
    p_transfer_id,
    p_received_quantity,
    p_destination_shelf_id,
    p_return_remaining,
    p_reason
  );

  INSERT INTO public.stock_transfer_receipt_idempotency
    (transfer_id,operation_id,user_id,payload_hash,result)
  VALUES (p_transfer_id,p_operation_id,v_user,v_hash,v_result);

  RETURN v_result || jsonb_build_object('already_processed',false);
END;
$function$;

REVOKE ALL ON FUNCTION public.receive_stock_transfer_quantity_at_shelf_v2(uuid,numeric,uuid,boolean,text,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.receive_stock_transfer_quantity_at_shelf_v2(uuid,numeric,uuid,boolean,text,uuid) TO authenticated;
