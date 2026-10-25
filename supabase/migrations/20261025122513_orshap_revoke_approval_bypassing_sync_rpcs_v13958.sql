-- Retire the legacy direct-posting sync RPCs.
-- The current client does not call these endpoints. They directly mutate stock and
-- create APPROVED transactions using only the operation's create permission, which
-- bypasses the configured transaction approval workflow. Do not expose them to clients
-- until offline sync can create pending vouchers and use the canonical approval path.

REVOKE ALL PRIVILEGES ON FUNCTION public.process_sync_batch(text, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL PRIVILEGES ON FUNCTION public.process_sync_batch_v2(text, jsonb)
  FROM PUBLIC, anon, authenticated;

DO $verification$
DECLARE
  v_legacy regprocedure := 'public.process_sync_batch(text,jsonb)'::regprocedure;
  v_v2 regprocedure := 'public.process_sync_batch_v2(text,jsonb)'::regprocedure;
  v_impl regprocedure := 'public.process_sync_batch_v2_impl(text,jsonb)'::regprocedure;
BEGIN
  IF has_function_privilege('anon', v_legacy, 'EXECUTE')
     OR has_function_privilege('authenticated', v_legacy, 'EXECUTE') THEN
    RAISE EXCEPTION 'Legacy process_sync_batch RPC remains executable by client roles';
  END IF;
  IF has_function_privilege('anon', v_v2, 'EXECUTE')
     OR has_function_privilege('authenticated', v_v2, 'EXECUTE') THEN
    RAISE EXCEPTION 'process_sync_batch_v2 RPC remains executable by client roles';
  END IF;
  IF has_function_privilege('anon', v_impl, 'EXECUTE')
     OR has_function_privilege('authenticated', v_impl, 'EXECUTE') THEN
    RAISE EXCEPTION 'Internal sync implementation must remain inaccessible to client roles';
  END IF;
END
$verification$;
