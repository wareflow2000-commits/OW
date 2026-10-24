'use strict';
const fs = require('node:fs');
const assert = require('node:assert/strict');

const html = fs.readFileSync('index.html', 'utf8');
const app = fs.readFileSync('app.js', 'utf8');
const css = fs.readFileSync('app.css', 'utf8');

function has(source, pattern, message) {
  assert.match(source, pattern, message);
}

has(html, /<html[^>]*lang="ar"[^>]*dir="rtl"/i, 'Document must default to Arabic RTL.');
has(app, /document\.documentElement\.dir\s*=\s*state\.lang\s*===\s*'ar'\s*\?\s*'rtl'\s*:\s*'ltr'/,
  'Language switching must update document direction.');
has(app, /class="app-shell \$\{state\.lang==='ar'\?'rtl':''\}"/,
  'Application shell must align its RTL class with the selected language.');
has(css, /\.app-shell\.rtl\s*>\s*\.v13-sidebar[^\{]*\{[^}]*right:\s*0/s,
  'RTL desktop sidebar must be on the right.');
has(css, /\.app-shell:not\(\.rtl\)\s*>\s*\.v13-sidebar[^\{]*\{[^}]*left:\s*0/s,
  'LTR desktop sidebar must be on the left.');
has(css, /\.app-shell\.rtl\s*>\s*\.main\s*\{[^}]*right:\s*var\(--app-sidebar-width\)/s,
  'RTL main column must start beside the right sidebar.');
has(css, /\.app-shell:not\(\.rtl\)\s*>\s*\.main\s*\{[^}]*left:\s*var\(--app-sidebar-width\)/s,
  'LTR main column must start beside the left sidebar.');
has(css, /@media\s*\(max-width:\s*800px\)[\s\S]*?\.v13-topbar,\s*\.topbar\s*\{[^}]*position:\s*fixed/s,
  'Mobile topbar must remain fixed.');
has(css, /@media\s*\(max-width:\s*800px\)[\s\S]*?\.v13-bottom-nav,\s*\.bottom-nav\s*\{[^}]*position:\s*fixed/s,
  'Mobile bottom navigation must remain fixed.');
has(css, /\.v13-bottom-nav,\s*\.bottom-nav\s*\{[^}]*grid-template-columns:\s*repeat\(5,\s*minmax\(0,\s*1fr\)\)/s,
  'Mobile navigation must have five columns.');
const nav = app.match(/function v13BottomNav\(\)\s*\{([\s\S]*?)\n\}/);
assert.ok(nav, 'Mobile navigation renderer must exist.');
const buttons = [...nav[1].matchAll(/<button\b/g)].length;
assert.equal(buttons, 5, 'Mobile navigation must render exactly five actions.');
has(nav[1], /data-action="v13-scan-qr"/, 'Center mobile action must be quick scan.');
has(nav[1], /data-page="dashboard"/, 'Mobile navigation must include Home.');
has(nav[1], /data-page="transactions"/, 'Mobile navigation must include Transactions.');
has(nav[1], /data-page="stocktake"/, 'Mobile navigation must include Stocktake.');
has(nav[1], /data-page="sync"/, 'Mobile navigation must include Sync.');
assert.doesNotMatch(app, /\b(?:zone_id|section_id)\b/, 'Active UI must not reference retired zone/section fields.');

console.log('UI layout contracts passed: RTL/LTR sidebar placement, fixed mobile bars, five-item navigation, quick scan, and retired location fields.');
