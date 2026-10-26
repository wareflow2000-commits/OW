import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync(new URL('../supabase/migrations/20261026061200_orshap_close_role_scope_rpc_gaps_v13958.sql', import.meta.url), 'utf8');

test('remaining stocktake RPCs use central role-and-user warehouse scope', () => {
  assert.match(migration, /close_stocktake_session_direct\(uuid\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_s\.warehouse_id\)/);
  assert.match(migration, /populate_stocktake_session_lines\(uuid\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_session\.warehouse_id\)/);
  assert.doesNotMatch(migration, /IF NOT public\.current_user_is_manager\(\)\s+AND NOT \(v_session\.warehouse_id/);
});

test('opening-balance batches validate scope for every warehouse group before posting', () => {
  assert.match(migration, /create_opening_balance_vouchers\(jsonb\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_warehouse\)/);
  assert.match(migration, /Opening-balance warehouse is outside the current user scope/);
});

test('supplier-return legacy overload cannot bypass role scope', () => {
  assert.match(migration, /create_stock_return_request\(uuid,text,text,uuid,numeric,text,date,uuid,text,text,text\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_shelf\.warehouse_id\)/);
  assert.doesNotMatch(migration, /cardinality\(COALESCE\(v_profile\.assigned_warehouse_ids/);
});

test('transfer-order receipt rejection checks the destination scope for each line', () => {
  assert.match(migration, /reject_stock_transfer_order\(uuid,text\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_line\.destination_warehouse_id\)/);
  assert.match(migration, /Transfer destination is outside the current user scope/);
});

test('migration fails closed if any live function body no longer matches its expected anchor', () => {
  assert.match(migration, /Expected exactly one patch anchor in %/);
  assert.match(migration, /Could not reconstruct function definition for %/);
});
