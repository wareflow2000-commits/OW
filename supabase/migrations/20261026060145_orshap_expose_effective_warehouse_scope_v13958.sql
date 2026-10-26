-- ORSHAP WMS v13.9.58: expose only the effective warehouse IDs for the signed-in user.
-- The function delegates authorization to the central role + user scope predicate.
BEGIN;

CREATE OR REPLACE FUNCTION public.current_user_accessible_warehouse_ids()
RETURNS TABLE(warehouse_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.current_user_is_active() THEN
    RAISE EXCEPTION 'Active authenticated user required' USING ERRCODE='42501';
  END IF;

  RETURN QUERY
  SELECT w.id
  FROM public.warehouses w
  WHERE public.current_user_can_access_warehouse(w.id)
  ORDER BY w.name, w.code, w.id;
END;
$function$;

REVOKE ALL ON FUNCTION public.current_user_accessible_warehouse_ids() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_accessible_warehouse_ids() TO authenticated, service_role;

COMMIT;
