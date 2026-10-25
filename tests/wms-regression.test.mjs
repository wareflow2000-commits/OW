'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

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
