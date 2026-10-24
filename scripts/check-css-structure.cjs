'use strict';
const fs = require('node:fs');
const css = fs.readFileSync('app.css', 'utf8');

let depth = 0;
let quote = null;
let inComment = false;
let line = 1;
for (let i = 0; i < css.length; i++) {
  const ch = css[i], next = css[i + 1];
  if (ch === '\n') line++;
  if (inComment) {
    if (ch === '*' && next === '/') { inComment = false; i++; }
    continue;
  }
  if (quote) {
    if (ch === '\\') { i++; continue; }
    if (ch === quote) quote = null;
    continue;
  }
  if (ch === '/' && next === '*') { inComment = true; i++; continue; }
  if (ch === '"' || ch === "'") { quote = ch; continue; }
  if (ch === '{') depth++;
  if (ch === '}') {
    depth--;
    if (depth < 0) {
      console.error('Unexpected closing brace in app.css at line ' + line);
      process.exit(1);
    }
  }
}
if (inComment) {
  console.error('Unclosed CSS comment in app.css');
  process.exit(1);
}
if (quote) {
  console.error('Unclosed CSS string in app.css');
  process.exit(1);
}
if (depth !== 0) {
  console.error('Unbalanced CSS braces in app.css: depth=' + depth);
  process.exit(1);
}
if (!css.includes('@media') || !css.includes(':root')) {
  console.error('Expected responsive rules or root design tokens are missing from app.css');
  process.exit(1);
}
console.log('CSS structural checks passed (' + css.split('\n').length + ' lines; balanced blocks, comments and strings).');
