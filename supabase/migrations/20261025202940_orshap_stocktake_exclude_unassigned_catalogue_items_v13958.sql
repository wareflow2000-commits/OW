-- ORSHAP WMS v13.9.58: stocktake lines must represent actual item/location stock rows.
-- The item master is location-neutral. Do not fabricate a zero-balance line for every
-- active catalogue item at every shelf; this creates false count scope and misleading variances.
CREATE OR REPLACE FUNCTION public.populate_stocktake_session_lines_internal(p_session_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
DECLARE
  v_session public.stocktake_sessions%ROWTYPE;
  v_count integer := 0;
  v_total integer := 0;
BEGIN
  SELECT *
    INTO v_session
    FROM public.stocktake_sessions
   WHERE id = p_session_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Stocktake session not found';
  END IF;
  IF v_session.status <> 'IN_PROGRESS' THEN
    RAISE EXCEPTION 'Only an in-progress session can be populated';
  END IF;

  INSERT INTO public.stocktake_lines
    (session_id, item_id, shelf_id, system_qty, counted_qty, is_settled, batch_no, expiry_date)
  SELECT
    p_session_id,
    src.item_id,
    src.shelf_id,
    src.system_qty,
    NULL,
    false,
    src.batch_no,
    src.expiry_date
  FROM (
    SELECT
      st.item_id,
      st.shelf_id,
      COALESCE(st.batch_no, '') AS batch_no,
      SUM(st.quantity)::numeric AS system_qty,
      MAX(st.expiry_date) AS expiry_date
    FROM public.stock AS st
    JOIN public.shelves AS sh
      ON sh.id = st.shelf_id
     AND sh.warehouse_id = v_session.warehouse_id
    JOIN public.storage_areas AS sa
      ON sa.id = sh.storage_area_id
     AND sa.warehouse_id = sh.warehouse_id
     AND COALESCE(sa.is_active, true) = true
    WHERE v_session.storage_area_id IS NULL
       OR sh.storage_area_id = v_session.storage_area_id
    GROUP BY st.item_id, st.shelf_id, COALESCE(st.batch_no, '')
  ) AS src
  WHERE NOT EXISTS (
    SELECT 1
      FROM public.stocktake_lines AS existing
     WHERE existing.session_id = p_session_id
       AND existing.item_id = src.item_id
       AND existing.shelf_id = src.shelf_id
       AND COALESCE(existing.batch_no, '') = COALESCE(src.batch_no, '')
  )
  ON CONFLICT (session_id, item_id, shelf_id, batch_no) DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  SELECT COUNT(*)::integer
    INTO v_total
    FROM public.stocktake_lines
   WHERE session_id = p_session_id;

  IF v_total = 0 THEN
    RAISE EXCEPTION 'No stock rows exist in the selected stocktake scope';
  END IF;

  RETURN v_total;
END;
$function$;
