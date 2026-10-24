-- ORSHAP WMS v13.9.58
-- Re-establish the safe compatibility wrapper after the shared historical migration.
-- The older 11-argument API must delegate to the owner-aware implementation and must
-- never insert transaction headers using retired zone_id/section_id columns.
CREATE OR REPLACE FUNCTION public.create_stock_return_request(
  p_return_id uuid,
  p_return_type text,
  p_reference_no text,
  p_item_id uuid,
  p_quantity numeric,
  p_batch_no text DEFAULT ''::text,
  p_expiry_date date DEFAULT NULL::date,
  p_shelf_id uuid DEFAULT NULL::uuid,
  p_supplier text DEFAULT NULL::text,
  p_external_reference text DEFAULT NULL::text,
  p_notes text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_owner uuid;
  v_owner_count integer := 0;
  v_user uuid := auth.uid();
  v_profile public.profiles%ROWTYPE;
  v_shelf public.shelves%ROWTYPE;
BEGIN
  IF v_user IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'An active authenticated user is required';
  END IF;

  IF NOT public.current_user_has_permission(
    CASE WHEN upper(COALESCE(p_return_type,'')) = 'RETURN_TO_SUPPLIER'
         THEN 'action:transaction:issue:create'
         ELSE 'action:transaction:grn:create' END
  ) THEN
    RAISE EXCEPTION 'Permission denied for return type %', p_return_type;
  END IF;

  IF upper(COALESCE(p_return_type,'')) = 'RETURN_TO_SUPPLIER' THEN
    SELECT * INTO v_shelf FROM public.shelves WHERE id = p_shelf_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Return shelf not found'; END IF;
    SELECT * INTO v_profile FROM public.profiles WHERE id = v_user AND status = 'ACTIVE';
    IF v_profile.role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER')
       AND (cardinality(COALESCE(v_profile.assigned_warehouse_ids, ARRAY[]::uuid[])) = 0
            OR NOT (v_shelf.warehouse_id = ANY(v_profile.assigned_warehouse_ids))) THEN
      RAISE EXCEPTION 'User is not assigned to the return warehouse';
    END IF;

    -- Replays inherit the owner recorded on the original request.
    SELECT tl.administrative_department_id
      INTO v_owner
      FROM public.transaction_lines tl
      JOIN public.transactions t ON t.id = tl.transaction_id
     WHERE t.id = p_return_id
       AND t.transaction_type = 'RETURN_TO_SUPPLIER'
       AND t.reference_no = btrim(COALESCE(p_reference_no,''))
       AND tl.item_id = p_item_id
       AND tl.shelf_id = p_shelf_id
       AND tl.quantity = p_quantity
       AND COALESCE(tl.batch_no,'') = COALESCE(p_batch_no,'')
       AND tl.administrative_department_id IS NOT NULL
     LIMIT 1;

    IF v_owner IS NULL THEN
      SELECT count(*), (array_agg(eligible.owner_id ORDER BY eligible.owner_id))[1]
        INTO v_owner_count, v_owner
        FROM (
          SELECT s.administrative_department_id AS owner_id
            FROM public.stock s
           WHERE s.item_id = p_item_id
             AND s.shelf_id = p_shelf_id
             AND s.batch_no = COALESCE(p_batch_no,'')
             AND s.administrative_department_id IS NOT NULL
           GROUP BY s.administrative_department_id
          HAVING sum(s.quantity) >= p_quantity
        ) AS eligible;

      IF v_owner_count <> 1 OR v_owner IS NULL THEN
        RAISE EXCEPTION 'Supplier return requires exactly one stock owner with sufficient quantity; select the owner explicitly in the current client';
      END IF;
    END IF;
  END IF;

  RETURN public.create_stock_return_request(
    p_return_id,
    p_return_type,
    p_reference_no,
    p_item_id,
    v_owner,
    p_quantity,
    p_batch_no,
    p_expiry_date,
    p_shelf_id,
    p_supplier,
    p_external_reference,
    p_notes
  );
END;
$function$;
