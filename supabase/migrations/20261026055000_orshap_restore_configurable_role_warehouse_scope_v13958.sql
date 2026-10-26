-- ORSHAP WMS v13.9.58: restore configurable warehouse scope per role.
-- Backward-compatible default: INHERIT preserves current user-assignment behavior.
BEGIN;

CREATE TABLE IF NOT EXISTS public.role_warehouse_scopes (
  role_name text PRIMARY KEY,
  scope_mode text NOT NULL DEFAULT 'INHERIT'
    CHECK (scope_mode IN ('INHERIT','SELECTED','ALL')),
  warehouse_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT role_warehouse_scopes_role_name_nonempty CHECK (btrim(role_name) <> ''),
  CONSTRAINT role_warehouse_scopes_selected_requires_ids
    CHECK (scope_mode <> 'SELECTED' OR cardinality(warehouse_ids) > 0),
  CONSTRAINT role_warehouse_scopes_nonselected_no_ids
    CHECK (scope_mode = 'SELECTED' OR cardinality(warehouse_ids) = 0)
);

ALTER TABLE public.role_warehouse_scopes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.role_warehouse_scopes FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.role_warehouse_scopes TO service_role;

CREATE OR REPLACE FUNCTION public.admin_get_role_warehouse_scope(p_role_name text)
RETURNS TABLE(scope_mode text, warehouse_ids uuid[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor_role text;
  v_actor_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode = '28000';
  END IF;
  SELECT p.role, p.status INTO v_actor_role, v_actor_status
  FROM public.profiles p WHERE p.id = auth.uid();
  IF NOT FOUND OR v_actor_status <> 'ACTIVE' OR v_actor_role <> 'SUPER_ADMIN' THEN
    RAISE EXCEPTION 'Only an active SUPER_ADMIN may read role warehouse scopes' USING errcode = '42501';
  END IF;
  IF p_role_name IS NULL OR btrim(p_role_name) = '' THEN
    RAISE EXCEPTION 'Role name is required';
  END IF;
  RETURN QUERY
  SELECT COALESCE(s.scope_mode, 'INHERIT'),
         COALESCE(s.warehouse_ids, ARRAY[]::uuid[])
  FROM (SELECT 1) seed
  LEFT JOIN public.role_warehouse_scopes s ON s.role_name = p_role_name;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_replace_role_warehouse_scope(
  p_role_name text,
  p_scope_mode text,
  p_warehouse_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor_role text;
  v_actor_status text;
  v_mode text := upper(coalesce(p_scope_mode, ''));
  v_ids uuid[] := ARRAY[]::uuid[];
  v_missing integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode = '28000';
  END IF;
  SELECT p.role, p.status INTO v_actor_role, v_actor_status
  FROM public.profiles p WHERE p.id = auth.uid();
  IF NOT FOUND OR v_actor_status <> 'ACTIVE' OR v_actor_role <> 'SUPER_ADMIN' THEN
    RAISE EXCEPTION 'Only an active SUPER_ADMIN may edit role warehouse scopes' USING errcode = '42501';
  END IF;
  IF p_role_name IS NULL OR btrim(p_role_name) = '' OR p_role_name NOT IN (
    'SUPER_ADMIN','ADMIN','MANAGER','WAREHOUSE_MANAGER',
    'WAREHOUSE_KEEPER','STOREKEEPER','CLERK','AUDITOR','VIEWER'
  ) THEN
    RAISE EXCEPTION 'Unsupported role name';
  END IF;
  IF v_mode NOT IN ('INHERIT','SELECTED','ALL') THEN
    RAISE EXCEPTION 'Unsupported warehouse scope mode';
  END IF;
  SELECT coalesce(array_agg(DISTINCT x ORDER BY x), ARRAY[]::uuid[])
  INTO v_ids
  FROM unnest(coalesce(p_warehouse_ids, ARRAY[]::uuid[])) AS u(x)
  WHERE x IS NOT NULL;
  IF v_mode = 'SELECTED' AND cardinality(v_ids) = 0 THEN
    RAISE EXCEPTION 'Select at least one warehouse for SELECTED scope';
  END IF;
  IF v_mode <> 'SELECTED' THEN
    v_ids := ARRAY[]::uuid[];
  ELSE
    SELECT count(*) INTO v_missing
    FROM unnest(v_ids) u(id)
    WHERE NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id = u.id);
    IF v_missing > 0 THEN
      RAISE EXCEPTION 'One or more selected warehouses do not exist';
    END IF;
  END IF;
  INSERT INTO public.role_warehouse_scopes(role_name, scope_mode, warehouse_ids, updated_by, updated_at)
  VALUES (p_role_name, v_mode, v_ids, auth.uid(), now())
  ON CONFLICT (role_name) DO UPDATE
  SET scope_mode = EXCLUDED.scope_mode,
      warehouse_ids = EXCLUDED.warehouse_ids,
      updated_by = EXCLUDED.updated_by,
      updated_at = EXCLUDED.updated_at;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_get_role_warehouse_scope(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_replace_role_warehouse_scope(text, text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_role_warehouse_scope(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_replace_role_warehouse_scope(text, text, uuid[]) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.current_user_can_access_warehouse(p_warehouse_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN auth.uid() IS NULL OR p_warehouse_id IS NULL THEN false
    ELSE EXISTS (
      SELECT 1
      FROM public.profiles p
      LEFT JOIN public.role_warehouse_scopes rs ON rs.role_name = p.role
      WHERE p.id = (SELECT auth.uid())
        AND p.status = 'ACTIVE'
        AND (
          -- A user-level explicit assignment is always an additional restriction.
          (cardinality(coalesce(p.assigned_warehouse_ids, ARRAY[]::uuid[])) > 0
            AND p_warehouse_id = ANY(p.assigned_warehouse_ids))
          OR
          -- With no user assignment, a selected role scope grants only its selected warehouses.
          (cardinality(coalesce(p.assigned_warehouse_ids, ARRAY[]::uuid[])) = 0
            AND rs.scope_mode = 'SELECTED'
            AND p_warehouse_id = ANY(rs.warehouse_ids))
          OR
          -- ALL is an explicit role-level choice; INHERIT preserves legacy admin-only global access.
          (cardinality(coalesce(p.assigned_warehouse_ids, ARRAY[]::uuid[])) = 0
            AND (
              rs.scope_mode = 'ALL'
              OR (coalesce(rs.scope_mode, 'INHERIT') = 'INHERIT'
                  AND p.role IN ('SUPER_ADMIN','ADMIN'))
            ))
        )
        -- When both role and user have explicit lists, effective access is their intersection.
        AND (rs.scope_mode IS DISTINCT FROM 'SELECTED' OR p_warehouse_id = ANY(rs.warehouse_ids))
    )
  END;
$function$;

REVOKE ALL ON FUNCTION public.current_user_can_access_warehouse(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_can_access_warehouse(uuid) TO authenticated, service_role;


-- Atomically persist the role's permission set and warehouse scope from the single UI save action.
CREATE OR REPLACE FUNCTION public.admin_save_role_access_config(
  p_role_name text,
  p_permission_keys text[],
  p_scope_mode text,
  p_warehouse_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor_role text;
  v_actor_status text;
  v_mode text := upper(coalesce(p_scope_mode, ''));
  v_ids uuid[] := ARRAY[]::uuid[];
  v_unknown_count integer;
  v_missing integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode = '28000';
  END IF;
  SELECT p.role, p.status INTO v_actor_role, v_actor_status
  FROM public.profiles p WHERE p.id = auth.uid();
  IF NOT FOUND OR v_actor_status <> 'ACTIVE' OR v_actor_role <> 'SUPER_ADMIN' THEN
    RAISE EXCEPTION 'Only an active SUPER_ADMIN may edit role access configuration' USING errcode = '42501';
  END IF;
  IF p_role_name IS NULL OR btrim(p_role_name) = '' OR p_role_name NOT IN (
    'SUPER_ADMIN','ADMIN','MANAGER','WAREHOUSE_MANAGER',
    'WAREHOUSE_KEEPER','STOREKEEPER','CLERK','AUDITOR','VIEWER'
  ) THEN
    RAISE EXCEPTION 'Unsupported role name';
  END IF;
  IF v_mode NOT IN ('INHERIT','SELECTED','ALL') THEN
    RAISE EXCEPTION 'Unsupported warehouse scope mode';
  END IF;
  SELECT count(*) INTO v_unknown_count
  FROM (
    SELECT DISTINCT u.k
    FROM unnest(coalesce(p_permission_keys, ARRAY[]::text[])) AS u(k)
    WHERE u.k IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.permissions p WHERE p.key = u.k)
  ) unknown_keys;
  IF v_unknown_count > 0 THEN
    RAISE EXCEPTION 'One or more permission keys are unknown';
  END IF;
  SELECT coalesce(array_agg(DISTINCT x ORDER BY x), ARRAY[]::uuid[])
  INTO v_ids
  FROM unnest(coalesce(p_warehouse_ids, ARRAY[]::uuid[])) AS u(x)
  WHERE x IS NOT NULL;
  IF v_mode = 'SELECTED' AND cardinality(v_ids) = 0 THEN
    RAISE EXCEPTION 'Select at least one warehouse for SELECTED scope';
  END IF;
  IF v_mode <> 'SELECTED' THEN
    v_ids := ARRAY[]::uuid[];
  ELSE
    SELECT count(*) INTO v_missing
    FROM unnest(v_ids) u(id)
    WHERE NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id = u.id);
    IF v_missing > 0 THEN
      RAISE EXCEPTION 'One or more selected warehouses do not exist';
    END IF;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('orshap:admin_save_role_access_config'));
  DELETE FROM public.role_permissions rp WHERE rp.role_name = p_role_name;
  INSERT INTO public.role_permissions(role_name, permission_key)
  SELECT p_role_name, keys.k
  FROM (
    SELECT DISTINCT u.k
    FROM unnest(coalesce(p_permission_keys, ARRAY[]::text[])) AS u(k)
    WHERE u.k IS NOT NULL
  ) keys;
  INSERT INTO public.role_warehouse_scopes(role_name, scope_mode, warehouse_ids, updated_by, updated_at)
  VALUES (p_role_name, v_mode, v_ids, auth.uid(), now())
  ON CONFLICT (role_name) DO UPDATE
  SET scope_mode = EXCLUDED.scope_mode,
      warehouse_ids = EXCLUDED.warehouse_ids,
      updated_by = EXCLUDED.updated_by,
      updated_at = EXCLUDED.updated_at;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_save_role_access_config(text, text[], text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_save_role_access_config(text, text[], text, uuid[]) TO authenticated, service_role;

COMMIT;
