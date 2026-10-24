-- ORSHAP WMS v13.9.58
-- Archive legacy zone/section snapshot IDs before removing those duplicate location
-- dimensions from both ledgers. The canonical location is storage_area_id + shelf_id;
-- historical identifiers are preserved inside JSON for audit traceability.
DO $migration$
DECLARE
  r record;
  v_def text;
  v_new text;
BEGIN
  -- Update every inventory-ledger writer that still inserted legacy location columns.
  FOR r IN
    SELECT p.oid, p.oid::regprocedure::text AS signature
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.prokind='f'
       AND pg_get_functiondef(p.oid) ILIKE '%INSERT INTO public.inventory_ledger%'
       AND pg_get_functiondef(p.oid) ILIKE '%zone_id%'
     ORDER BY p.oid::regprocedure::text
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def,
      $re$warehouse_id[[:space:]]*,[[:space:]]*zone_id[[:space:]]*,[[:space:]]*section_id[[:space:]]*,[[:space:]]*shelf_id$re$,
      'warehouse_id,shelf_id','gi');
    v_new := regexp_replace(v_new,
      $re$warehouse_id[[:space:]]*,[[:space:]]*zone_id[[:space:]]*,[[:space:]]*shelf_id$re$,
      'warehouse_id,shelf_id','gi');
    v_new := regexp_replace(v_new,
      $re$(VALUES[[:space:]]*[(].*p_warehouse_id)[[:space:]]*,[[:space:]]*p_zone_id[[:space:]]*,[[:space:]]*p_section_id[[:space:]]*,[[:space:]]*p_shelf_id$re$,
      $rep$\1,p_shelf_id$rep$,'gis');
    v_new := regexp_replace(v_new,
      $re$(VALUES[[:space:]]*[(].*p_warehouse_id)[[:space:]]*,[[:space:]]*p_zone_id[[:space:]]*,[[:space:]]*p_shelf_id$re$,
      $rep$\1,p_shelf_id$rep$,'gis');
    v_new := regexp_replace(v_new,
      $re$v_line\.warehouse_id[[:space:]]*,[[:space:]]*v_line\.zone_id[[:space:]]*,[[:space:]]*v_line\.section_id[[:space:]]*,[[:space:]]*v_line\.shelf_id$re$,
      'v_line.warehouse_id,v_line.shelf_id','gi');
    IF v_new = v_def OR
       left(substring(v_new from position('INSERT INTO public.inventory_ledger' in v_new)), position('VALUES' in substring(v_new from position('INSERT INTO public.inventory_ledger' in v_new)))) ILIKE '%zone_id%' THEN
      RAISE EXCEPTION 'Could not safely remove legacy inventory-ledger columns from %',r.signature;
    END IF;
    EXECUTE v_new;
  END LOOP;

  -- Update transaction-ledger writers while retaining the old RPC parameters for
  -- positional-call compatibility. Those parameters are intentionally ignored.
  FOR r IN
    SELECT p.oid, p.oid::regprocedure::text AS signature
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.prokind='f'
       AND pg_get_functiondef(p.oid) ILIKE '%INSERT INTO transaction_ledger%'
       AND pg_get_functiondef(p.oid) ILIKE '%zone_id%'
     ORDER BY p.oid::regprocedure::text
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def,
      $re$warehouse_id[[:space:]]*,[[:space:]]*zone_id[[:space:]]*,[[:space:]]*section_id[[:space:]]*,[[:space:]]*shelf_id$re$,
      'warehouse_id,shelf_id','gi');
    v_new := regexp_replace(v_new,
      $re$p_warehouse_id[[:space:]]*,[[:space:]]*p_zone_id[[:space:]]*,[[:space:]]*p_section_id[[:space:]]*,[[:space:]]*p_shelf_id$re$,
      'p_warehouse_id,p_shelf_id','gi');
    IF v_new = v_def OR
       left(substring(v_new from position('INSERT INTO transaction_ledger' in v_new)), position('VALUES' in substring(v_new from position('INSERT INTO transaction_ledger' in v_new)))) ILIKE '%zone_id%' THEN
      RAISE EXCEPTION 'Could not safely remove legacy transaction-ledger columns from %',r.signature;
    END IF;
    EXECUTE v_new;
  END LOOP;

  -- Verify no remaining active ledger INSERT lists require the retiring columns.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.prokind='f'
       AND (
         (pg_get_functiondef(p.oid) ILIKE '%INSERT INTO public.inventory_ledger%'
          AND left(substring(pg_get_functiondef(p.oid) from position('INSERT INTO public.inventory_ledger' in pg_get_functiondef(p.oid))), position('VALUES' in substring(pg_get_functiondef(p.oid) from position('INSERT INTO public.inventory_ledger' in pg_get_functiondef(p.oid))))) ILIKE '%zone_id%')
         OR
         (pg_get_functiondef(p.oid) ILIKE '%INSERT INTO transaction_ledger%'
          AND left(substring(pg_get_functiondef(p.oid) from position('INSERT INTO transaction_ledger' in pg_get_functiondef(p.oid))), position('VALUES' in substring(pg_get_functiondef(p.oid) from position('INSERT INTO transaction_ledger' in pg_get_functiondef(p.oid))))) ILIKE '%zone_id%')
       )
  ) THEN
    RAISE EXCEPTION 'Legacy ledger INSERT dependencies remain; ledger columns were not dropped';
  END IF;
END;
$migration$;

UPDATE public.inventory_ledger
   SET metadata = COALESCE(metadata,'{}'::jsonb)
       || CASE WHEN zone_id IS NOT NULL THEN jsonb_build_object('legacy_zone_id',zone_id) ELSE '{}'::jsonb END
       || CASE WHEN section_id IS NOT NULL THEN jsonb_build_object('legacy_section_id',section_id) ELSE '{}'::jsonb END
 WHERE zone_id IS NOT NULL OR section_id IS NOT NULL;

UPDATE public.transaction_ledger
   SET details = COALESCE(details,'{}'::jsonb)
       || CASE WHEN zone_id IS NOT NULL THEN jsonb_build_object('legacy_zone_id',zone_id) ELSE '{}'::jsonb END
       || CASE WHEN section_id IS NOT NULL THEN jsonb_build_object('legacy_section_id',section_id) ELSE '{}'::jsonb END
 WHERE zone_id IS NOT NULL OR section_id IS NOT NULL;

ALTER TABLE public.inventory_ledger
  DROP COLUMN IF EXISTS zone_id,
  DROP COLUMN IF EXISTS section_id;

ALTER TABLE public.transaction_ledger
  DROP COLUMN IF EXISTS zone_id,
  DROP COLUMN IF EXISTS section_id;
