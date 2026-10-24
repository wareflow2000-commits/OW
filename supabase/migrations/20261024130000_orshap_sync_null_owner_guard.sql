-- ORSHAP WMS v13.9.58
-- Reject offline-sync stock rows whose owning department cannot be resolved.
-- A shelf default is only used when no stock owner row exists; it must not
-- silently reassign a legacy NULL-owner balance.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.process_sync_batch_v2_impl(text,jsonb)'::regprocedure;
  v_def text;
  v_old text := E'END IF;\n      IF v_owner IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.administrative_departments d WHERE d.id=v_owner AND d.is_active=true) THEN';
  v_new text := E'END IF;\n      IF v_owner IS NULL THEN\n        RAISE EXCEPTION ''Stock-owning department is unresolved for offline sync'';\n      END IF;\n      IF NOT EXISTS(SELECT 1 FROM public.administrative_departments d WHERE d.id=v_owner AND d.is_active=true) THEN';
BEGIN
  v_def := pg_get_functiondef(v_sig);
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'Expected post-resolution owner validation not found; migration aborted';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  IF position(v_new IN v_def) = 0 THEN
    RAISE EXCEPTION 'Owner validation patch verification failed; migration aborted';
  END IF;
  EXECUTE v_def;
END;
$migration$;
