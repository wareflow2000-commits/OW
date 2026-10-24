'use strict';
const fs = require('node:fs');

const html = fs.readFileSync('index.html', 'utf8');
const worker = fs.readFileSync('sw.js', 'utf8');
const app = fs.readFileSync('app.js', 'utf8');
if (/rpc\(['"]receive_stock_transfer['"]/.test(app)) {
  console.error('Legacy non-operation-ID transfer receipt RPC is still called by app.js.');
  process.exitCode = 1;
}
if (!app.includes('p_operation_id:receiptOperationId')) {
  console.error('Operation-ID protected receipt RPC call is missing.');
  process.exitCode = 1;
}
if (/\b(?:zone_id|section_id)\b/.test(app)) {
  console.error('Retired zone/section database fields are still referenced by app.js.');
  process.exitCode = 1;
}
const localAssets = [...html.matchAll(/(?:src|href)="(\.\/[^"]+\.(?:js|css)(?:\?[^"]*)?)"/g)]
  .map(match => match[1]);
const missing = localAssets.filter(asset => !worker.includes("'" + asset + "'"));
const missingFiles = localAssets
  .map(asset => asset.split('?')[0])
  .filter(asset => !fs.existsSync(asset));
if (missingFiles.length) {
  console.error('index.html references missing local assets:', missingFiles.join(', '));
  process.exitCode = 1;
}
if (missing.length) {
  console.error('Service-worker APP_SHELL is missing index.html assets:', missing.join(', '));
  process.exitCode = 1;
}
if (!worker.includes(String.raw`const isAppAsset = /\.(?:js|css)$/.test(url.pathname);`)) {
  console.error('Service-worker app asset matcher is missing or malformed.');
  process.exitCode = 1;
}
if (!/request\.mode === 'navigate'/.test(worker) || !/caches\.match\('\.\/index\.html'\)/.test(worker)) {
  console.error('Service-worker offline navigation fallback is missing.');
  process.exitCode = 1;
}
if (process.exitCode) process.exit(process.exitCode);
console.log('Service-worker shell references match index.html (' + localAssets.length + ' JS/CSS assets).');
