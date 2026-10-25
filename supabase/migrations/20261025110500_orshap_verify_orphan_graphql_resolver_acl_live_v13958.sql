-- ORSHAP WMS v13.9.58
-- Reconcile the live ACL: the previous migration history says the orphan
-- graphql_public resolver was revoked, but a fresh pg_proc ACL inspection still
-- showed EXECUTE for PUBLIC, anon, and authenticated.
-- The application uses PostgREST/RPC and has no GraphQL client references.
-- This affects only this exact resolver; no inventory or ledger data is touched.

DO $migration$
DECLARE
  v_function regprocedure := to_regprocedure('graphql_public.graphql(text,text,jsonb,jsonb)');
BEGIN
  IF v_function IS NULL THEN
    RAISE NOTICE 'graphql_public.graphql resolver is absent; no ACL change needed';
    RETURN;
  END IF;

  EXECUTE 'REVOKE ALL PRIVILEGES ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) TO service_role';

  IF has_function_privilege('anon', v_function, 'EXECUTE')
     OR has_function_privilege('authenticated', v_function, 'EXECUTE')
     OR has_function_privilege('public', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'GraphQL resolver ACL verification failed: client execution remains granted';
  END IF;

  IF NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'GraphQL resolver ACL verification failed: service_role lost EXECUTE';
  END IF;
END
$migration$;
