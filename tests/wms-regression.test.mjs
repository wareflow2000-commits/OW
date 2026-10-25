import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const app = fs.readFileSync(new URL('../app.js', import.meta.url), 'utf8');

test('app.js parses as JavaScript', () => {
  assert.doesNotThrow(() => new vm.Script(app, { filename: 'app.js' }));
});

test('reports filter uses globally scoped access predicate', () => {
  const start = app.indexOf('function c10ReportFilterMarkup(');
  const end = app.indexOf('\nfunction c10Reports(', start);
  assert.ok(start >= 0 && end > start, 'report filter renderer exists');
  const source = app.slice(start, end);
  assert.match(source, /v5All\('warehouses'\)\.filter\(w=>c10AccessibleWarehouse\(w\.id\)\)/);
  assert.doesNotMatch(source, /v13TxAllowedWarehouses\s*\(/);
});

test('About page defines its own translator outside the v13 IIFE', () => {
  const start = app.indexOf('function aboutPage()');
  assert.ok(start >= 0, 'aboutPage exists');
  const end = app.indexOf('\n}', start);
  const source = app.slice(start, end);
  assert.match(source, /const tx\s*=\s*\(ar,en\)=>state\.lang==='ar'\?ar:en/);
});

test('dashboard and transactions route to a non-blocking New Request modal', () => {
  assert.match(app, /data-action="v12-new-tx">[^<]*\$\{tx\('معاملة جديدة','New transaction'\)\}/);
  assert.match(app, /data-action="v12-new-tx">＋ \$\{T\(\)\.newReq\}/);
  const start = app.indexOf("if(a==='v12-new-tx'){");
  const end = app.indexOf("if(a==='v12-tx-add-line'){", start);
  const handler = app.slice(start, end);
  assert.match(handler, /txModal\(\);void v12RequestTransactionReference\(state\.v12ReferenceRequestId\);return/);
  assert.doesNotMatch(handler, /await rpc\('next_transaction_reference'/);
  assert.match(app, /async function v12RequestTransactionReference\(requestId\)[\s\S]{0,1400}Promise\.race/);
});

test('transaction form uses an explicit bridge to scoped v13 selector helpers', () => {
  const txIndex = app.indexOf('function txModal()');
  const start = app.lastIndexOf('(function(){', txIndex);
  const end = app.indexOf('\\n})();', start);
  const txScope = app.slice(start, end);
  assert.match(app, /window\.orshapTxChoices=Object\.freeze/);
  assert.doesNotMatch(txScope, /\\bv13Tx(?:AllowedWarehouses|ShelfIsValid|StockRows|ItemChoices|ShelfChoices|ShelfLabel|OwnerChoices|BatchChoices)\\b/);
  assert.match(txScope, /function v12AllowedWarehouses\(\)/);
});
 
test('v13 field handlers call the v12 transaction modal through an explicit bridge', () => {
  assert.ok(app.includes('window.orshapV12TxModal=txModal;'));
  const designStart = app.indexOf('/* ORSHAP WMS V13 — design-system');
  const start = app.indexOf('(function(){', designStart);
  const end = app.indexOf('\\n})();', start);
  const designScope = app.slice(start, end);
  assert.doesNotMatch(designScope, /\\btxModal\\s*\\(/);
  assert.match(designScope, /window\.orshapV12TxModal\?\.\(\)/);
});

test('New Request click events bypass legacy delegated handlers', () => {
  assert.ok(app.includes("const btn=e.target.closest('[data-action=\"v12-new-tx\"]')"));
  assert.ok(app.includes("handleAction('v12-new-tx');"));
});

test('transaction shelves are filtered to active valid warehouse-area relationships', () => {
  assert.match(app, /function v13TxShelfIsValid\(sh\)[\s\S]{0,350}area\.warehouse_id===sh\.warehouse_id/);
  const start = app.indexOf('function v13TxShelfChoices(');
  const end = app.indexOf('\nfunction v13TxSuggestedWarehouse(', start);
  const source = app.slice(start, end);
  assert.match(source, /v13TxShelfIsValid\(sh\)/);
});

test('inbound owner defaults require an explicit valid shelf default; issue defaults require one stock owner', () => {
  const start = app.indexOf('function v13TxUniqueOwner(');
  const end = app.indexOf('\nfunction v13TxShelfLabel(', start);
  const source = app.slice(start, end);
  assert.match(source, /default_administrative_department_id/);
  assert.match(source, /owners\.length===1\?owners\[0\]\.id:''/);
});

test('transfer and return location selectors require an active area and a valid shelf', () => {
  assert.match(app, /function v13TxShelfIsValid\(sh\)/);
  assert.match(app, /validShelves=shelves\.filter\(sh=>sh\.warehouse_id===wh&&!!area&&sh\.storage_area_id===area/);
  assert.match(app, /const checkLocation=\(s,wh,area\)=>!!s&&v12ShelfIsValid\(s\)&&s\.warehouse_id===wh&&s\.storage_area_id===area/);
});

test('return destination does not auto-select a department merely because only one exists', () => {
  assert.doesNotMatch(app, /ownerOptions\.some\(dep=>dep\.id===defaultOwnerId\)\?defaultOwnerId:\(ownerOptions\.length===1\?ownerOptions\[0\]\.id:''\)/);
});

test('both transaction movement UIs hide orphan shelves until a valid storage area is selected', () => {
  assert.match(app, /mShelves=v5All\('shelves'\)\.filter\(v12ShelfIsValid\)/);
  assert.match(app, /validShelves=mShelves\.filter\(sh=>sh\.warehouse_id===wh&&!!area&&sh\.storage_area_id===area\)/);
  assert.match(app, /validShelves=shelves\.filter\(sh=>sh\.warehouse_id===wh&&!!area&&sh\.storage_area_id===area/);
});

test('shelf facility modal refreshes storage areas when its warehouse changes', () => {
  assert.ok(app.includes("const v8fac=el.closest('#v8-facility-form');if(v8fac&&el.name==='warehouse_id')"));
  assert.ok(app.includes('v13SetOptions(areaSel,areas,selected'));
});
