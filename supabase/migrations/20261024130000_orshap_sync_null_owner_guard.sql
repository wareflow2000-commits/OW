-- ORSHAP WMS v13.9.58
-- Fix offline-sync owner resolution when the only matching stock owner is NULL.
-- This migration refuses to infer ownership when no valid owner can be resolved.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.process_sync_batch_v2_impl(text,jsonb)'::regprocedure;
  v_def text;
  v_old text := 'ELSIF v_owner_count = 0 THEN';
  v_new text := 'ELSIF v_owner_count = 0 OR v_owner IS NULL THEN';
BEGIN
  v_def := pg_get_functiondef(v_sig);
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'Expected owner-resolution branch not found; migration aborted';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  IF position(v_new IN v_def) = 0 THEN
    RAISE EXCEPTION 'Owner-resolution patch verification failed; migration aborted';
  END IF;
  EXECUTE v_def;
END;
$migration$;
