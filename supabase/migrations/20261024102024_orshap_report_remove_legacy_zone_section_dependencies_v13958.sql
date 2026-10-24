-- ORSHAP WMS v13.9.58
-- Keep the existing RPC signature for compatibility while removing runtime joins
-- to the deleted sections table and all operational zone/section filtering.
CREATE OR REPLACE FUNCTION public.get_stock_summary_report_internal(
  p_start_date timestamp with time zone,
  p_end_date timestamp with time zone,
  p_warehouse_id uuid DEFAULT NULL::uuid,
  p_zone_id uuid DEFAULT NULL::uuid,
  p_section_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(
  item_code text,
  item_name_en text,
  item_name_ar text,
  item_category text,
  section_name text,
  opening_stock numeric,
  total_in numeric,
  total_out numeric,
  current_stock numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth', 'pg_temp'
AS $function$
BEGIN
  -- p_zone_id and p_section_id remain only for RPC signature compatibility.
  RETURN QUERY
  WITH ledger_summary AS (
    SELECT il.item_id,
      SUM(CASE WHEN il.is_opening_balance=TRUE OR il.occurred_at<p_start_date THEN il.delta ELSE 0 END) AS opening,
      SUM(CASE
        WHEN il.is_opening_balance=FALSE AND il.occurred_at>=p_start_date AND il.occurred_at<=p_end_date
          AND il.delta>0
          AND NOT (
            COALESCE(il.metadata,'{}'::jsonb) ? 'transfer_id'
            OR COALESCE(il.metadata->>'reference_type','') LIKE 'STOCK_TRANSFER%'
            OR COALESCE(il.notes,'') ILIKE '%Transfer=%'
            OR COALESCE(il.source_ref,'') ~* '^TRF[-_].*-(OUT|IN|RET-RCV)$'
          )
        THEN il.delta ELSE 0 END) AS qty_in,
      SUM(CASE
        WHEN il.is_opening_balance=FALSE AND il.occurred_at>=p_start_date AND il.occurred_at<=p_end_date
          AND il.delta<0
          AND NOT (
            COALESCE(il.metadata,'{}'::jsonb) ? 'transfer_id'
            OR COALESCE(il.metadata->>'reference_type','') LIKE 'STOCK_TRANSFER%'
            OR COALESCE(il.notes,'') ILIKE '%Transfer=%'
            OR COALESCE(il.source_ref,'') ~* '^TRF[-_].*-(OUT|IN|RET-RCV)$'
          )
        THEN ABS(il.delta) ELSE 0 END) AS qty_out
    FROM public.inventory_ledger il
    WHERE p_warehouse_id IS NULL OR il.warehouse_id=p_warehouse_id
    GROUP BY il.item_id
  ),
  current_stock_actual AS (
    SELECT s.item_id,SUM(s.quantity) AS total_qty
    FROM public.stock s
    LEFT JOIN public.shelves sh ON sh.id=s.shelf_id
    WHERE p_warehouse_id IS NULL OR sh.warehouse_id=p_warehouse_id
    GROUP BY s.item_id
  )
  SELECT i.code::text,i.name_en::text,i.name_ar::text,i.category::text,
    '-'::text,
    COALESCE(ls.opening,0)::numeric,
    COALESCE(ls.qty_in,0)::numeric,
    COALESCE(ls.qty_out,0)::numeric,
    COALESCE(csa.total_qty,0)::numeric
  FROM public.items i
  LEFT JOIN ledger_summary ls ON ls.item_id=i.id
  LEFT JOIN current_stock_actual csa ON csa.item_id=i.id
  WHERE i.status='ACTIVE' AND (ls.item_id IS NOT NULL OR csa.item_id IS NOT NULL)
  ORDER BY i.code;
END;
$function$;
