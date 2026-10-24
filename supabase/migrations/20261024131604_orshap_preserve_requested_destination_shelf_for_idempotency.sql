-- Preserve the originally requested destination shelf separately from the actual receipt shelf.
-- This keeps retry comparison stable when the receiver assigns or changes the physical shelf.
ALTER TABLE public.stock_transfers
  ADD COLUMN IF NOT EXISTS requested_destination_shelf_id uuid;

UPDATE public.stock_transfers
SET requested_destination_shelf_id=destination_shelf_id
WHERE requested_destination_shelf_id IS NULL AND destination_shelf_id IS NOT NULL;

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.stock_transfers'::regclass
      AND conname='stock_transfers_requested_destination_shelf_id_fkey'
  ) THEN
    ALTER TABLE public.stock_transfers
      ADD CONSTRAINT stock_transfers_requested_destination_shelf_id_fkey
      FOREIGN KEY (requested_destination_shelf_id) REFERENCES public.shelves(id) ON DELETE RESTRICT NOT VALID;
    ALTER TABLE public.stock_transfers VALIDATE CONSTRAINT stock_transfers_requested_destination_shelf_id_fkey;
  END IF;
END;
$migration$;
CREATE INDEX IF NOT EXISTS idx_stock_transfers_requested_destination_shelf_id
  ON public.stock_transfers(requested_destination_shelf_id);

DO $migration$
DECLARE
  v_sig regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_sig:='public.dispatch_stock_transfer(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text)'::regprocedure;
  v_def:=pg_get_functiondef(v_sig);
  v_old:='v_existing.destination_shelf_id IS DISTINCT FROM p_destination_shelf_id';
  v_new:='v_existing.requested_destination_shelf_id IS DISTINCT FROM p_destination_shelf_id';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Canonical transfer destination retry check not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='destination_warehouse_id,destination_shelf_id,status,notes,created_by,dispatched_by,source_transaction_id';
  v_new:='destination_warehouse_id,destination_shelf_id,requested_destination_shelf_id,status,notes,created_by,dispatched_by,source_transaction_id';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Canonical transfer insert columns not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='v_dst.warehouse_id,p_destination_shelf_id,v_status,p_notes,v_user,v_user,v_src_tx';
  v_new:='v_dst.warehouse_id,p_destination_shelf_id,p_destination_shelf_id,v_status,p_notes,v_user,v_user,v_src_tx';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Canonical transfer insert values not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;

  v_sig:='public.dispatch_stock_transfer_with_destination_warehouse_owner_aware(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text,uuid)'::regprocedure;
  v_def:=pg_get_functiondef(v_sig);
  v_old:='v_existing.destination_shelf_id IS DISTINCT FROM p_destination_shelf_id';
  v_new:='v_existing.requested_destination_shelf_id IS DISTINCT FROM p_destination_shelf_id';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Owner-aware helper destination retry check not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='destination_warehouse_id,destination_shelf_id,status,notes,created_by,dispatched_by,source_transaction_id';
  v_new:='destination_warehouse_id,destination_shelf_id,requested_destination_shelf_id,status,notes,created_by,dispatched_by,source_transaction_id';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Owner-aware helper insert columns not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  v_old:='p_destination_warehouse_id,p_destination_shelf_id,v_status,p_notes,v_user,v_user,v_src_tx';
  v_new:='p_destination_warehouse_id,p_destination_shelf_id,p_destination_shelf_id,v_status,p_notes,v_user,v_user,v_src_tx';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Owner-aware helper insert values not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;

  v_sig:='public.dispatch_stock_transfer_order_v2(uuid,text,uuid,uuid,jsonb,text)'::regprocedure;
  v_def:=pg_get_functiondef(v_sig);
  v_old:='st.destination_shelf_id IS DISTINCT FROM NULLIF(j.line->>''destination_shelf_id'','''')::uuid';
  v_new:='st.requested_destination_shelf_id IS DISTINCT FROM NULLIF(j.line->>''destination_shelf_id'','''')::uuid';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Transfer order requested destination comparison not found'; END IF;
  v_def:=replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$migration$;
