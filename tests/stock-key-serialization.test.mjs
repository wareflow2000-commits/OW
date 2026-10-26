import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync(new URL('../supabase/migrations/20261026070000_orshap_serialize_stock_key_approval_v13958.sql', import.meta.url), 'utf8');

test('approval serializes canonical stock keys before reading current quantity', () => {
  assert.match(migration, /approve_transaction\(uuid\)/);
  assert.match(migration, /pg_advisory_xact_lock\(hashtextextended\(/);
  assert.match(migration, /v_rec\.item_id::text\s*\|\| ':' \|\| v_rec\.shelf_id::text/);
  assert.match(migration, /COALESCE\(v_rec\.batch_no, ''\)/);
  assert.match(migration, /COALESCE\(v_rec\.administrative_department_id::text, ''\)/);
  assert.match(migration, /FOR UPDATE;/);
});

test('approval lock migration fails closed if the stock read anchor drifts', () => {
  assert.match(migration, /Expected exactly one stock-key read anchor in approve_transaction/);
  assert.match(migration, /Could not reconstruct approve_transaction definition/);
  assert.match(migration, /already has a stock-key advisory lock/);
});

test('internal transfer, receipt, and return helpers use effective role warehouse scope', () => {
  assert.match(migration, /dispatch_stock_transfer_with_destination_warehouse_owner_aware/);
  assert.match(migration, /receive_stock_transfer_quantity_at_shelf_v2/);
  assert.match(migration, /confirm_stock_transfer_return/);
  assert.match(migration, /confirm_stock_transfer_return_v2\\(uuid\\)/);
  assert.match(migration, /Expected one return-confirmation wrapper anchor/);
  assert.match(migration, /receive_stock_transfer\(uuid\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_src\.warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_t\.destination_warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_t\.source_warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_transfer\.destination_warehouse_id\)/);
  assert.match(migration, /Expected one legacy return-confirmation scope gate/);
  assert.match(migration, /Expected one legacy receive scope gate/);
});

test('RLS write policies for transactions and stocktake enforce effective warehouse scope', () => {
  for (const policy of [
    'stocktake_sessions_permission_insert',
    'stocktake_sessions_permission_update',
    'stocktake_sessions_permission_delete',
    'transactions_permission_insert',
    'transactions_permission_update',
    'transactions_permission_delete',
    'transaction_lines_permission_insert',
    'transaction_lines_permission_update',
    'transaction_lines_permission_delete',
    'stocktake_lines_permission_insert',
    'stocktake_lines_permission_update',
    'stocktake_lines_permission_delete'
  ]) assert.match(migration, new RegExp('ALTER POLICY ' + policy + ' ON public\\.'));
  assert.match(migration, /current_user_can_access_warehouse\(warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(t\.warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(s\.warehouse_id\)/);
});
