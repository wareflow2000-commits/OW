-- ORSHAP WMS v13.9.58
-- The application uses PostgREST REST/RPC and has no GraphQL client calls.
-- Prior REVOKE attempts could not remove grants owned by the managed pg_graphql extension.
-- Drop the unused extension to close /graphql/v1. This does not alter warehouse tables or stock data.
DROP EXTENSION IF EXISTS pg_graphql;
