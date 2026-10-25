-- ORSHAP WMS v13.9.58
-- Security follow-up to 20261025051616_orshap_disable_unused_pg_graphql_api_v13958.sql.
-- The pg_graphql extension is absent, but a standalone graphql_public.graphql resolver
-- remains and still has EXECUTE granted to PUBLIC, anon, and authenticated.
-- app.js has no GraphQL client references; the application uses PostgREST REST/RPC.
-- This revokes only the orphan resolver's client execution privilege. It does not alter
-- warehouse data, inventory ledgers, transaction records, RLS policies, or other RPCs.
--
-- Rollback (only if GraphQL is intentionally re-enabled):
-- GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) TO PUBLIC, anon, authenticated;

DO $migration$
BEGIN
  IF to_regprocedure('graphql_public.graphql(text,text,jsonb,jsonb)') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) TO service_role;
  END IF;
END
$migration$;
