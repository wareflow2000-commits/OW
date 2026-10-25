-- ORSHAP WMS v13.9.58
-- Retire the unused GraphQL entry point from client-facing roles.
-- The WMS frontend uses Supabase PostgREST/RPC and contains no GraphQL client calls.
-- This changes function ACL only; it does not touch inventory or ledger data.
-- Keep service_role access for trusted server-side maintenance that explicitly uses GraphQL.
BEGIN;

DO $migration$
DECLARE
  v_function regprocedure := to_regprocedure('graphql_public.graphql(text,text,jsonb,jsonb)');
  v_oid oid;
BEGIN
  IF v_function IS NULL THEN
    RAISE NOTICE 'graphql_public.graphql resolver is absent; no ACL change needed';
    RETURN;
  END IF;

  v_oid := v_function::oid;

  REVOKE ALL PRIVILEGES
    ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb)
    FROM PUBLIC, anon, authenticated;

  GRANT EXECUTE
    ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb)
    TO service_role;

  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GraphQL resolver ACL verification failed: client role can still execute';
  END IF;

  -- PUBLIC is a pseudo-role, not a real role accepted by has_function_privilege().
  -- Inspect the effective ACL directly; grantee OID 0 represents PUBLIC.
  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    CROSS JOIN LATERAL aclexplode(
      COALESCE(p.proacl, acldefault('f', p.proowner))
    ) acl
    WHERE p.oid = v_oid
      AND acl.grantee = 0
      AND acl.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'GraphQL resolver ACL verification failed: PUBLIC still has EXECUTE';
  END IF;

  IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GraphQL resolver ACL verification failed: service_role lost EXECUTE';
  END IF;
END
$migration$;

COMMIT;
