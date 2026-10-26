import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync(new URL('../supabase/migrations/20261026063000_orshap_remove_legacy_scope_gates_v13958.sql', import.meta.url), 'utf8');

test('owner-aware transfer dispatch uses the effective source warehouse predicate', () => {
  assert.match(migration, /dispatch_stock_transfer\(uuid,text,uuid,uuid,numeric,text,date,uuid,uuid,text\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_src\.warehouse_id\)/);
  assert.doesNotMatch(migration, /cardinality\(COALESCE\(v_profile\.assigned_warehouse_ids/);
});

test('stock return creation uses the effective shelf warehouse predicate', () => {
  assert.match(migration, /create_stock_return_request\(uuid,text,text,uuid,uuid,numeric,text,date,uuid,text,text,text\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_shelf\.warehouse_id\)/);
  assert.doesNotMatch(migration, /cardinality\(COALESCE\(v_profile\.assigned_warehouse_ids/);
});

test('migration fails closed if either live function definition has drifted', () => {
  assert.match(migration, /Expected exactly one patch anchor in %/);
  assert.match(migration, /Could not reconstruct function definition for %/);
});
