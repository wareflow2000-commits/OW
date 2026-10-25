-- ORSHAP WMS v13.9.58
-- Corrective follow-up: execute the privilege changes dynamically so the DO block
-- applies the ACL change on environments where the orphan resolver still exists.
-- The application has no GraphQL client calls; only the orphan GraphQL resolver is changed.
-- No inventory data, tables, RLS policies, or other RPC privileges are modified.
--
-- Rollback (only if GraphQL is intentionally re-enabled):
-- GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) TO PUBLIC, anon, authenticated;

DO $migration$
BEGIN
  IF to_regprocedure('graphql_public.graphql(text,text,jsonb,jsonb)') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) TO service_role';
  END IF;
END
$migration$;
