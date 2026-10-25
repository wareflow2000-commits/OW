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

test('dashboard and transactions both route to the same new-transaction action', () => {
  assert.match(app, /data-action="v12-new-tx">[^<]*\$\{tx\('معاملة جديدة','New transaction'\)\}/);
  assert.match(app, /data-action="v12-new-tx">＋ \$\{T\(\)\.newReq\}/);
  assert.match(app, /if\(a==='v12-new-tx'\)[\s\S]{0,1500}catch\(e\)\{state\.v12TxMeta\.reference_no='';txModal\(\);say\(/);
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
