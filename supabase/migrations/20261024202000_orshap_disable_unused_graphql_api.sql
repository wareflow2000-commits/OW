-- ORSHAP WMS v13.9.58
-- The browser client uses Supabase Auth + PostgREST RPC/table endpoints only;
-- it does not use pg_graphql. Disable the unused GraphQL resolver for public
-- API roles while preserving REST grants and RLS policies required by the app.
REVOKE EXECUTE ON FUNCTION graphql.resolve(text, jsonb, text, jsonb)
  FROM anon, authenticated;
