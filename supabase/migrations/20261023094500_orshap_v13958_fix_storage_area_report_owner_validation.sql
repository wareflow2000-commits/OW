-- Correct report validation to use the current authoritative single-owner relation.
-- The shared mapping table is not yet written by every area-creation path.
CREATE OR REPLACE FUNCTION public.get_stock_summary_by_storage_area(
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_warehouse_id uuid DEFAULT NULL,
  p_storage_area_id uuid DEFAULT NULL,
  p_category_id uuid DEFAULT NULL
)
RETURNS TABLE(item_code text,item_name_en text,item_name_ar text,category_name text,opening_stock numeric,total_in numeric,total_out numeric,current_stock numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_role text;
  v_status text;
  v_assigned uuid[];
BEGIN
  IF v_user_id IS NULL OR NOT public.current_user_is_active() THEN RAISE EXCEPTION 'An active authenticated user is required'; END IF;
  IF NOT (public.current_user_has_permission('page:reports:access') OR public.current_user_has_permission('table:reports:view')) THEN RAISE EXCEPTION 'You do not have permission to view stock summary reports'; END IF;
  SELECT p.role,p.status,COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[]) INTO v_role,v_status,v_assigned FROM public.profiles p WHERE p.id=v_user_id;
  IF NOT FOUND OR v_status<>'ACTIVE' THEN RAISE EXCEPTION 'Active user profile required'; END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date<p_start_date THEN RAISE EXCEPTION 'A valid report date range is required'; END IF;
  IF v_role NOT IN ('SUPER_ADMIN','ADMIN','MANAGER') AND (p_warehouse_id IS NULL OR NOT (p_warehouse_id=ANY(v_assigned))) THEN RAISE EXCEPTION 'Select a warehouse assigned to your account'; END IF;
  -- storage_areas.warehouse_id remains authoritative until shared-area ownership is fully rolled out.
  IF p_storage_area_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.storage_areas a WHERE a.id=p_storage_area_id AND a.is_active=true AND (p_warehouse_id IS NULL OR a.warehouse_id=p_warehouse_id)) THEN
    RAISE EXCEPTION 'Storage area is not active in the selected warehouse';
  END IF;
  RETURN QUERY
  WITH ledger_summary AS (
    SELECT il.item_id,
      SUM(CASE WHEN il.is_opening_balance=TRUE OR il.occurred_at<p_start_date THEN il.delta ELSE 0 END) opening,
      SUM(CASE WHEN il.is_opening_balance=FALSE AND il.occurred_at>=p_start_date AND il.occurred_at<=p_end_date AND il.delta>0 THEN il.delta ELSE 0 END) qty_in,
      SUM(CASE WHEN il.is_opening_balance=FALSE AND il.occurred_at>=p_start_date AND il.occurred_at<=p_end_date AND il.delta<0 THEN ABS(il.delta) ELSE 0 END) qty_out
    FROM public.inventory_ledger il
    WHERE (p_warehouse_id IS NULL OR il.warehouse_id=p_warehouse_id)
      AND (p_storage_area_id IS NULL OR il.storage_area_id=p_storage_area_id)
    GROUP BY il.item_id
  ), current_stock_actual AS (
    SELECT s.item_id,SUM(s.quantity) total_qty
    FROM public.stock s LEFT JOIN public.shelves sh ON sh.id=s.shelf_id
    WHERE (p_warehouse_id IS NULL OR sh.warehouse_id=p_warehouse_id)
      AND (p_storage_area_id IS NULL OR s.storage_area_id=p_storage_area_id)
    GROUP BY s.item_id
  )
  SELECT i.code,i.name_en,i.name_ar,COALESCE(ic.name,NULLIF(i.category,''),'-'),
    COALESCE(ls.opening,0),COALESCE(ls.qty_in,0),COALESCE(ls.qty_out,0),COALESCE(csa.total_qty,0)
  FROM public.items i
  LEFT JOIN public.item_categories ic ON ic.id=i.category_id
  LEFT JOIN ledger_summary ls ON ls.item_id=i.id
  LEFT JOIN current_stock_actual csa ON csa.item_id=i.id
  WHERE i.status='ACTIVE' AND (p_category_id IS NULL OR i.category_id=p_category_id)
    AND (ls.item_id IS NOT NULL OR csa.item_id IS NOT NULL)
  ORDER BY i.code;
END;
$function$;
REVOKE ALL ON FUNCTION public.get_stock_summary_by_storage_area(timestamptz,timestamptz,uuid,uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_stock_summary_by_storage_area(timestamptz,timestamptz,uuid,uuid,uuid) TO authenticated,service_role;
