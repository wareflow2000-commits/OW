-- ORSHAP WMS v13.9.58
-- Close the unused pg_graphql API for public client roles. The browser
-- application uses Supabase Auth and PostgREST only; it contains no GraphQL
-- client calls. Revoke PUBLIC as well because function EXECUTE is inherited.
REVOKE ALL ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION graphql.resolve(text, jsonb, text, jsonb)
  FROM PUBLIC, anon, authenticated;
