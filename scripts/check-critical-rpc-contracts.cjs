'use strict';
const fs = require('node:fs');
const assert = require('node:assert/strict');

const read = path => fs.readFileSync(path, 'utf8');
const receipt = read('supabase/migrations/20261024125800_orshap_transfer_receipt_idempotency_rpc.sql');
const retire = read('supabase/migrations/20261024135550_orshap_retire_non_idempotent_partial_receipt_rpcs.sql');
const sync = read('supabase/migrations/20261024123305_orshap_sync_payload_idempotency_guard.sql');
const dispatch = read('supabase/migrations/20261024130653_orshap_transfer_dispatch_owner_update_and_idempotency_fix.sql');
const app = read('app.js');

function has(source, pattern, message) {
  assert.match(source, pattern, message);
}

has(receipt, /p_operation_id\s+uuid/i, 'Receipt RPC must require a stable operation ID.');
has(receipt, /PRIMARY KEY\s*\(\s*transfer_id\s*,\s*operation_id\s*\)/i, 'Receipt idempotency key must be unique per transfer and operation.');
has(receipt, /FROM public\.stock_transfers\s+WHERE id=p_transfer_id\s+FOR UPDATE/i, 'Receipt must lock its transfer before processing.');
has(receipt, /v_hash\s*:=\s*md5\(jsonb_build_object/i, 'Receipt payload must be fingerprinted.');
has(receipt, /v_existing\.user_id IS DISTINCT FROM v_user/i, 'Receipt retry must be bound to the original user.');
has(receipt, /v_existing\.payload_hash IS DISTINCT FROM v_hash/i, 'Receipt retry must reject changed payloads.');
has(receipt, /already_processed',true/i, 'Receipt retry must report a replay.');
has(receipt, /GRANT EXECUTE ON FUNCTION public\.receive_stock_transfer_quantity_at_shelf_v2\(uuid,numeric,uuid,boolean,text,uuid\) TO authenticated/i, 'Only the operation-ID receipt endpoint should be granted to authenticated callers.');
has(retire, /receive_stock_transfer_quantity_at_shelf_v2\(uuid,numeric,uuid,boolean,text\)[\s\S]*?FROM PUBLIC, anon, authenticated/i, 'Five-argument receipt RPC must be retired.');

has(sync, /v_payload_hash\s*:=\s*md5\(v_op::text\)/i, 'Offline sync operations must be fingerprinted.');
has(sync, /FOR UPDATE/i, 'Offline sync retry must lock the existing operation record.');
has(sync, /payload_hash[\s\S]{0,500}different payload|different payload[\s\S]{0,500}payload_hash/i, 'Offline sync must detect operation-ID reuse with changed payload.');
has(sync, /'ALREADY_PROCESSED'/i, 'Offline sync must return a non-mutating replay result.');
has(dispatch, /v_existing\.created_by IS DISTINCT FROM v_user/i, 'Transfer dispatch retries must enforce original creator identity.');
has(dispatch, /v_existing\.notes IS DISTINCT FROM p_notes/i, 'Transfer dispatch retries must reject changed notes.');

has(app, /orshap_transfer_receipt_op:'\+id/, 'UI must persist a stable receipt operation ID per transfer.');
has(app, /p_operation_id:receiptOperationId/, 'UI must send the persisted operation ID to the guarded receipt RPC.');
assert.doesNotMatch(app, /rpc\(['"]receive_stock_transfer['"]/, 'UI must not call the legacy one-shot receipt RPC directly.');
assert.doesNotMatch(app, /\b(?:zone_id|section_id)\b/, 'UI must not reference retired zone/section fields.');

console.log('Critical RPC contract checks passed: receipt idempotency, legacy RPC retirement, offline-sync replay guards, transfer dispatch retry identity, and UI operation-ID wiring.');
