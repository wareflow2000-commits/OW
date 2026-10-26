import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync(new URL('../supabase/migrations/20261026062000_orshap_align_role_scope_rpc_predicates_v13958.sql', import.meta.url), 'utf8');

test('transfer dispatch and replay use the central effective warehouse predicate', () => {
  assert.match(migration, /dispatch_stock_transfer_order_v2/);
  assert.match(migration, /current_user_can_access_warehouse\(p_source_warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_src\.warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_existing\.source_warehouse_id\)/);
});

test('transfer receipt and return review preserve role-selected access while enforcing endpoint scope', () => {
  assert.match(migration, /current_user_can_access_warehouse\(v_transfer\.destination_warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_t\.source_warehouse_id\)/);
  assert.match(migration, /Expected one legacy return-review assignment gate, found %/);
});

test('idempotent return replay validates the current effective scope', () => {
  assert.match(migration, /sh\.warehouse_id=v_existing\.warehouse_id AND public\.current_user_can_access_warehouse\(sh\.warehouse_id\)/);
});

test('stock summary filters both inventory and ledger data to effective warehouse scope', () => {
  assert.match(migration, /No warehouse is accessible to this account/);
  assert.match(migration, /current_user_can_access_warehouse\(il\.warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(sh\.warehouse_id\)/);
});

test('every migration patch fails closed on definition drift', () => {
  assert.match(migration, /Expected exactly one patch anchor in %/);
  assert.match(migration, /Could not reconstruct function definition for %/);
});
