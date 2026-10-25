-- ORSHAP WMS v13.9.58
-- Verified follow-up: the orphan graphql_public.graphql resolver still had EXECUTE
-- for PUBLIC/anon/authenticated after earlier attempts. The live application uses
-- PostgREST REST/RPC and has no GraphQL client references.
-- Revoke client execution only on this exact resolver; keep service_role access.
-- No warehouse, inventory, ledger, transaction, RLS, or other RPC changes.
--
-- Rollback only if GraphQL is intentionally re-enabled:
-- GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb)
--   TO PUBLIC, anon, authenticated;

DO $migration$
BEGIN
  IF to_regprocedure('graphql_public.graphql(text,text,jsonb,jsonb)') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) TO service_role;
  END IF;
END
$migration$;
