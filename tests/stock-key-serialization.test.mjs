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
