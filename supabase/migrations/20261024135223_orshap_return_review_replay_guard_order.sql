-- ORSHAP WMS v13.9.58
-- Return-review replay should report the already-reviewed state before checking
-- whether a pending quantity remains. This avoids a misleading "no pending quantity"
-- error after a legitimate rejection has cancelled the request.
DO $migration$
DECLARE
  v_sig regprocedure := 'public.review_stock_transfer_return_request(uuid,text,text)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_old text;
  v_new text;
BEGIN
  v_old := E'IF v_t.status <> ''RETURN_IN_TRANSIT''\n'
        || E'                                                                                                                                          OR COALESCE(v_t.return_requested_quantity, 0) <= COALESCE(v_t.returned_quantity, 0) THEN\n'
        || E'                                                                                                                                              RAISE EXCEPTION ''No pending return quantity exists for this transfer line'';\n'
        || E'                                                                                                                                                END IF;';

  v_new := E'IF COALESCE(v_t.return_review_status, ''PENDING'') <> ''PENDING'' THEN\n'
        || E'                                                                                                                                                                          RAISE EXCEPTION ''This return request has already been reviewed'';\n'
        || E'                                                                                                                                                                            END IF;\n'
        || E'IF v_t.status <> ''RETURN_IN_TRANSIT''\n'
        || E'                                                                                                                                          OR COALESCE(v_t.return_requested_quantity, 0) <= COALESCE(v_t.returned_quantity, 0) THEN\n'
        || E'                                                                                                                                              RAISE EXCEPTION ''No pending return quantity exists for this transfer line'';\n'
        || E'                                                                                                                                                END IF;';

  IF position(v_old IN v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate return-review pending-quantity guard; function left unchanged';
  END IF;

  v_def := replace(v_def,v_old,v_new);
  -- Remove the now-duplicate later reviewed-state guard.
  v_old := E'IF COALESCE(v_t.return_review_status, ''PENDING'') <> ''PENDING'' THEN\n'
        || E'                                                                                                                                                                          RAISE EXCEPTION ''This return request has already been reviewed'';\n'
        || E'                                                                                                                                                                            END IF;\n\n'
        || E'                                                                                                                                                                              IF v_decision = ''ACCEPT'' THEN';
  v_new := E'IF v_decision = ''ACCEPT'' THEN';
  IF position(v_old IN v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate duplicate return-review guard after reorder; function left unchanged';
  END IF;
  v_def := replace(v_def,v_old,v_new);
  EXECUTE v_def;
END;
$migration$;
