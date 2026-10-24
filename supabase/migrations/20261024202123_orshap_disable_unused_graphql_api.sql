-- ORSHAP WMS v13.9.58
-- Attempted to restrict the unused pg_graphql resolver for client roles.
-- The managed extension owner retains the effective ACL in the current project;
-- see SECURITY_REVIEW_V13958.md. This statement is retained to reflect the
-- migration that was executed and does not constitute a verified fix.
REVOKE EXECUTE ON FUNCTION graphql.resolve(text, jsonb, text, jsonb)
  FROM anon, authenticated;
