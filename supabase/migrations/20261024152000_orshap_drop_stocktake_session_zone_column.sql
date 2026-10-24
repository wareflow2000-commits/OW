-- Remove the obsolete stocktake zone dimension after confirming no sessions use it.
DO $migration$
DECLARE
  v_sig regprocedure;
  v_def text;
  v_old text;
  v_new text;
  v_names regprocedure[] := ARRAY[
    'public.process_stocktake_settlement_direct_internal(uuid,uuid[],text)'::regprocedure,
    'public.process_stocktake_settlement_direct_internal_with_direction(uuid,uuid[],text,jsonb)'::regprocedure
  ];
  v_i integer;
BEGIN
  FOR v_i IN 1..array_length(v_names,1) LOOP
    v_sig:=v_names[v_i];
    v_def:=pg_get_functiondef(v_sig);
    v_old:='warehouse_id,zone_id,storage_area_id,notes';
    v_new:='warehouse_id,storage_area_id,notes';
    IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Stocktake transaction header column list not found in %',v_sig; END IF;
    v_def:=replace(v_def,v_old,v_new);
    v_old:='v_session.zone_id,v_session.storage_area_id';
    v_new:='v_session.storage_area_id';
    IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'Stocktake transaction header values not found in %',v_sig; END IF;
    v_def:=replace(v_def,v_old,v_new);
    v_def:=replace(v_def,'v_session.zone_id','NULL::uuid');
    EXECUTE v_def;
  END LOOP;
  IF EXISTS(SELECT 1 FROM public.stocktake_sessions WHERE zone_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Cannot drop stocktake_sessions.zone_id while populated values remain';
  END IF;
END;
$migration$;
ALTER TABLE public.stocktake_sessions DROP COLUMN IF EXISTS zone_id;
