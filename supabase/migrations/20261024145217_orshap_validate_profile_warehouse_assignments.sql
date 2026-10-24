-- ORSHAP WMS v13.9.58
-- Prevent stale UUID arrays from granting or silently losing warehouse access.
-- Existing invalid assignments are not rewritten automatically; administrators must
-- explicitly correct them to valid warehouses.
CREATE OR REPLACE FUNCTION public.validate_profile_warehouse_assignments()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public'
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM unnest(COALESCE(NEW.assigned_warehouse_ids,ARRAY[]::uuid[])) AS assigned(id)
      LEFT JOIN public.warehouses w ON w.id=assigned.id
     WHERE assigned.id IS NULL OR w.id IS NULL
  ) THEN
    RAISE EXCEPTION 'assigned_warehouse_ids contains a null or nonexistent warehouse ID'
      USING ERRCODE='23503';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS profiles_validate_assigned_warehouse_ids ON public.profiles;
CREATE TRIGGER profiles_validate_assigned_warehouse_ids
BEFORE INSERT OR UPDATE OF assigned_warehouse_ids
ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.validate_profile_warehouse_assignments();

CREATE OR REPLACE FUNCTION public.prevent_delete_assigned_warehouse()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public'
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM public.profiles p
     WHERE OLD.id = ANY(COALESCE(p.assigned_warehouse_ids,ARRAY[]::uuid[]))
  ) THEN
    RAISE EXCEPTION 'Cannot delete a warehouse while it is assigned to one or more profiles'
      USING ERRCODE='23503';
  END IF;
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS warehouses_prevent_delete_if_assigned ON public.warehouses;
CREATE TRIGGER warehouses_prevent_delete_if_assigned
BEFORE DELETE ON public.warehouses
FOR EACH ROW
EXECUTE FUNCTION public.prevent_delete_assigned_warehouse();

REVOKE ALL ON FUNCTION public.validate_profile_warehouse_assignments() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prevent_delete_assigned_warehouse() FROM PUBLIC, anon, authenticated;
