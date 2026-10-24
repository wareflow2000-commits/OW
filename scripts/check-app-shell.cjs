'use strict';
const fs = require('node:fs');

const html = fs.readFileSync('index.html', 'utf8');
const worker = fs.readFileSync('sw.js', 'utf8');
const localAssets = [...html.matchAll(/(?:src|href)="(\.\/[^"]+\.(?:js|css)(?:\?[^"]*)?)"/g)]
  .map(match => match[1]);
const missing = localAssets.filter(asset => !worker.includes("'" + asset + "'"));
if (missing.length) {
  console.error('Service-worker APP_SHELL is missing index.html assets:', missing.join(', '));
  process.exitCode = 1;
}
if (!/const isAppAsset = \/\.\(\?:js\|css\)\$\/\.test\(url\.pathname\);/.test(worker)) {
  console.error('Service-worker app asset matcher is missing or malformed.');
  process.exitCode = 1;
}
if (!/request\.mode === 'navigate'/.test(worker) || !/caches\.match\('\.\/index\.html'\)/.test(worker)) {
  console.error('Service-worker offline navigation fallback is missing.');
  process.exitCode = 1;
}
if (process.exitCode) process.exit(process.exitCode);
console.log('Service-worker shell references match index.html (' + localAssets.length + ' JS/CSS assets).');
