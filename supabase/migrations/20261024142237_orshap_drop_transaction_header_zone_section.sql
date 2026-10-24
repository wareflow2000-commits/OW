-- ORSHAP WMS v13.9.58
-- Retire unused zone/section columns from transaction headers.
-- The current application no longer sends these fields, and the live table has
-- zero populated values. Historical ledger columns are deliberately retained in
-- this migration because they contain legacy zone IDs and require archival first.
DO $migration$
DECLARE
  r record;
  v_def text;
  v_new text;
  v_changed boolean;
BEGIN
  FOR r IN
    SELECT p.oid, p.oid::regprocedure::text AS signature
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prokind = 'f'
       AND pg_get_functiondef(p.oid) ILIKE '%INSERT INTO public.transactions%'
       AND pg_get_functiondef(p.oid) ILIKE '%zone_id%'
     ORDER BY p.oid::regprocedure::text
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(
      v_def,
      $re$warehouse_id[[:space:]]*,[[:space:]]*zone_id[[:space:]]*,[[:space:]]*section_id[[:space:]]*,[[:space:]]*storage_area_id$re$,
      'warehouse_id,storage_area_id',
      'gi'
    );
    v_new := regexp_replace(
      v_new,
      $re$([[:alnum:]_.]+\.warehouse_id)[[:space:]]*,[[:space:]]*NULL[[:space:]]*,[[:space:]]*NULL[[:space:]]*,[[:space:]]*([[:alnum:]_.]+)$re$,
      $rep$\1,\2$rep$,
      'gi'
    );
    v_new := regexp_replace(
      v_new,
      $re$NULLIF\(p_transaction->>'zone_id',''\)::uuid[[:space:]]*,[[:space:]]*NULLIF\(p_transaction->>'section_id',''\)::uuid[[:space:]]*,[[:space:]]*$re$,
      '',
      'gi'
    );
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
    END IF;
  END LOOP;

  -- The transfer-source finalizer used to select these header columns only to
  -- forward them into the ledger snapshot. Keep its record shape but return NULL.
  SELECT pg_get_functiondef(p.oid)
    INTO v_def
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public'
     AND p.oid='public.finalize_stock_transfer_source_issue(uuid,uuid)'::regprocedure;
  v_new := replace(v_def, 't.zone_id,t.section_id', 'NULL::uuid AS zone_id,NULL::uuid AS section_id');
  IF v_new IS DISTINCT FROM v_def THEN
    EXECUTE v_new;
  END IF;

  -- Abort rather than dropping columns if any live function still directly
  -- expects transaction header zone/section fields.
  IF EXISTS (
    SELECT 1
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.prokind='f'
       AND (
         pg_get_functiondef(p.oid) ILIKE '%t.zone_id%'
         OR pg_get_functiondef(p.oid) ILIKE '%t.section_id%'
         OR pg_get_functiondef(p.oid) ILIKE '%warehouse_id,zone_id,section_id,storage_area_id%'
         OR pg_get_functiondef(p.oid) ILIKE '%warehouse_id, zone_id, section_id, storage_area_id%'
       )
  ) THEN
    RAISE EXCEPTION 'Legacy transaction header column references remain; columns were not dropped';
  END IF;
END;
$migration$;

ALTER TABLE public.transactions
  DROP COLUMN IF EXISTS zone_id,
  DROP COLUMN IF EXISTS section_id;
