-- ORSHAP WMS v13.9.58
-- Follow-up attempt to disable pg_graphql for public client roles.
-- The managed extension owner retains the effective ACL in the current project;
-- see SECURITY_REVIEW_V13958.md. This statement is retained to reflect the
-- migration that was executed and does not constitute a verified fix.
REVOKE ALL ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION graphql.resolve(text, jsonb, text, jsonb)
  FROM PUBLIC, anon, authenticated;
