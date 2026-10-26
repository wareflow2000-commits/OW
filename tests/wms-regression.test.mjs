import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const app = fs.readFileSync(new URL('../app.js', import.meta.url), 'utf8');
const css = fs.readFileSync(new URL('../app.css', import.meta.url), 'utf8');

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

test('transaction form uses explicit bridges instead of cross-IIFE helpers', () => {
  const txIndex = app.indexOf('function txModal()');
  const start = app.lastIndexOf('(function(){', txIndex);
  const end = app.indexOf('\n})();', start);
  const txScope = app.slice(start, end);
  assert.match(app, /window\.orshapTxChoices=Object\.freeze/);
  assert.match(app, /window\.orshapV12TxModal=txModal;/);
  assert.doesNotMatch(txScope, /\bv13Tx(?:AllowedWarehouses|ShelfIsValid|StockRows|ItemChoices|ShelfChoices|ShelfLabel|OwnerChoices|BatchChoices)\b/);
  assert.doesNotMatch(txScope, /\btx\s*\(/);
  assert.doesNotMatch(txScope, /\bwhName\s*\(/);
  assert.match(txScope, /function v12AllowedWarehouses\(\)/);
  assert.match(txScope, /function v12Translate\(ar,en\)/);
});
 
test('v13 shelf labels use the defined warehouse-name helper', () => {
  const designStart = app.indexOf('/* ORSHAP WMS V13 — design-system');
  const start = app.indexOf('(function(){', designStart);
  const end = app.indexOf('\n})();', start);
  const designScope = app.slice(start, end);
  assert.doesNotMatch(designScope, /\bwhName\s*\(/);
  assert.match(designScope, /v13WarehouseName\(sh\.warehouse_id\)/);
});

test('v13 field handlers call the v12 transaction modal through an explicit bridge', () => {
  assert.ok(app.includes('window.orshapV12TxModal=txModal;'));
  const designStart = app.indexOf('/* ORSHAP WMS V13 — design-system');
  const start = app.indexOf('(function(){', designStart);
  const end = app.indexOf('\n})();', start);
  const designScope = app.slice(start, end);
  assert.doesNotMatch(designScope, /\btxModal\s*\(/);
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

test('offline New Request requests a safe reference and uses a clearly marked local fallback only on connectivity failure', () => {
  const start = app.indexOf("if(a==='v12-new-tx'){");
  const end = app.indexOf("if(a==='v12-tx-retry-reference')", start);
  assert.ok(start >= 0 && end > start, 'canonical New Request handler exists');
  const handler = app.slice(start, end);
  assert.match(handler, /if\(!navigator\.onLine\)\{txModal\(\);v12SetLocalTransactionReference\(state\.v12ReferenceRequestId\);say\(/);
  assert.doesNotMatch(handler, /reference_no\s*=\s*['"]OFF-/);
  assert.match(handler, /v12RequestTransactionReference\(state\.v12ReferenceRequestId\)/);
  assert.match(app, /function v12SetLocalTransactionReference\(requestId\)/);
});

test('system boolean settings are normalized to canonical TRUE/FALSE values', () => {
  const start = app.indexOf('function s81Set(');
  const end = app.indexOf('function s81Print', start);
  assert.ok(start >= 0 && end > start, 'system setting writer exists');
  const queued = [];
  const sandbox = {
    V5_DB: { systemSettings: [] },
    s81Ensure() {},
    v7Queue(...args) { queued.push(args); }
  };
  vm.createContext(sandbox);
  vm.runInContext(app.slice(start, end), sandbox);
  sandbox.s81Set('REQUIRE_APPROVAL', true);
  sandbox.s81Set('USE_UNIT_CONVERSION', false);
  sandbox.s81Set('FEATURE_USE_COST_SUPPLIER', 'true');
  sandbox.s81Set('COMPANY_NAME', true);
  assert.deepEqual(
    sandbox.V5_DB.systemSettings.map(row => [row.key, row.value]),
    [
      ['REQUIRE_APPROVAL', 'TRUE'],
      ['USE_UNIT_CONVERSION', 'FALSE'],
      ['FEATURE_USE_COST_SUPPLIER', 'TRUE'],
      ['COMPANY_NAME', 'true']
    ]
  );
  assert.equal(queued[0][2].value, 'TRUE', 'queued persistence must use the canonical value');
  assert.equal(queued[1][2].value, 'FALSE', 'queued persistence must use the canonical value');
});

test('legacy shelf form requires explicit storage-area choice when multiple areas exist', () => {
  const start = app.indexOf("const fac=el.closest('#v12-fac-form')");
  const end = app.indexOf("if(el.closest('#v12-tx-form')", start);
  assert.ok(start >= 0 && end > start, 'legacy facility dependency handler exists');
  const source = app.slice(start, end);
  assert.ok(source.includes("const areas=v5All('storage_areas').filter(a=>a.warehouse_id===wh&&a.is_active!==false),selected=areas.length===1?areas[0].id:''"));
  assert.ok(source.includes("v13SetOptions(areaSel,areas,selected") && source.includes(",true);"), 'the select must keep an empty option for explicit choice');
});

test('owning-department selection preserves valid choices and clears invalid ones', () => {
  const start = app.indexOf('function v13TxResolveOwnerSelection(');
  const end = app.indexOf('function v13TxShelfLabel', start);
  assert.ok(start >= 0 && end > start, 'owner-selection resolver exists');
  const choiceMap = new Map([
    ['item|shelf-multiple|ISSUE|warehouse', [{ id: 'owner-a' }, { id: 'owner-b' }]],
    ['item|shelf-b|ISSUE|warehouse', [{ id: 'owner-b' }, { id: 'owner-c' }]],
    ['item|shelf-single|ISSUE|warehouse', [{ id: 'owner-b' }]]
  ]);
  const sandbox = {
    v13TxOwnerChoices: (item, shelf, type, warehouse) => choiceMap.get(`${item}|${shelf}|${type}|${warehouse}`) || [],
    v13TxUniqueOwner: (item, shelf, type, warehouse) => {
      const choices = choiceMap.get(`${item}|${shelf}|${type}|${warehouse}`) || [];
      return choices.length === 1 ? choices[0].id : '';
    }
  };
  vm.createContext(sandbox);
  vm.runInContext(app.slice(start, end), sandbox);
  assert.equal(sandbox.v13TxResolveOwnerSelection('item', 'shelf-multiple', 'ISSUE', 'warehouse', 'owner-a'), 'owner-a');
  assert.equal(sandbox.v13TxResolveOwnerSelection('item', 'shelf-b', 'ISSUE', 'warehouse', 'owner-a'), '');
  assert.equal(sandbox.v13TxResolveOwnerSelection('item', 'shelf-single', 'ISSUE', 'warehouse', ''), 'owner-b');
  assert.equal(sandbox.v13TxResolveOwnerSelection('', 'shelf-single', 'ISSUE', 'warehouse', 'owner-b'), '');
});

test('transaction owner changes use the resolver and blank selections clear draft state', () => {
  assert.ok(app.includes("administrative_department_id:o.draft_administrative_department_id||''"), 'blank owner selections must clear draft state');
  assert.ok(!app.includes("administrative_department_id:o.draft_administrative_department_id||state.v12TxDraftLine?.administrative_department_id||''"), 'draft state must not restore a stale owner after the user clears it');
  assert.ok(!app.includes("priorShelfDefaultOwner="), 'unused legacy owner fallback state must be removed');
  assert.ok(app.includes("v13TxResolveOwnerSelection(itemId,state.v12TxDraftLine.shelf_id,state.v12TxMeta?.transaction_type,next,state.v12TxDraftLine.administrative_department_id)"), 'warehouse changes must preserve only a still-valid owner');
  assert.ok(app.includes("v13TxResolveOwnerSelection(el.value,state.v12TxDraftLine.shelf_id,type,state.v12TxWarehouseId,state.v12TxDraftLine.administrative_department_id)"), 'item changes must preserve only a still-valid owner');
  assert.ok(app.includes("v13TxResolveOwnerSelection(state.v12TxDraftLine.item_id,sh.id,state.v12TxMeta?.transaction_type,state.v12TxWarehouseId,state.v12TxDraftLine.administrative_department_id)"), 'shelf changes must preserve only a still-valid owner');
  assert.ok(app.includes("v13TxResolveOwnerSelection(state.v12TxDraftLine.item_id,state.v12TxDraftLine.shelf_id,el.value,state.v12TxWarehouseId||'',state.v12TxDraftLine.administrative_department_id)"), 'transaction-type changes must preserve only a still-valid owner');
});

test('stocktake settlement preserves owner dimension and rejects ambiguous owner allocation', () => {
  const migrationPath = new URL('../supabase/migrations/20261025095755_orshap_fix_stocktake_settlement_owner_conflict_v13958.sql', import.meta.url);
  const migration = fs.readFileSync(migrationPath, 'utf8');
  const start = migration.indexOf('CREATE OR REPLACE FUNCTION public.process_stocktake_settlement_direct_internal_with_direction');
  const end = migration.indexOf('COMMENT ON FUNCTION public.process_stocktake_settlement_direct_internal_with_direction', start);
  assert.ok(start >= 0 && end > start, 'owner-aware stocktake settlement migration exists');
  const source = migration.slice(start, end);
  assert.match(source, /LOCK TABLE public\.stock IN SHARE ROW EXCLUSIVE MODE/);
  assert.match(source, /v_owner_count > 1[\s\S]{0,220}spans multiple owning departments/);
  assert.match(source, /v_line\.item_id,v_line\.shelf_id,v_owner,v_new_qty/);
  assert.match(source, /ON CONFLICT \(item_id,shelf_id,batch_no,administrative_department_id\)/);
  assert.doesNotMatch(source, /ON CONFLICT \(item_id,shelf_id,batch_no\)/);
  assert.match(source, /'administrative_department_id',v_owner/);
});

test('live orphan GraphQL resolver ACL migration revokes client execution and verifies service_role', () => {
  const migrationPath = new URL('../supabase/migrations/20261025110500_orshap_verify_orphan_graphql_resolver_acl_live_v13958.sql', import.meta.url);
  const migration = fs.readFileSync(migrationPath, 'utf8');
  assert.ok(migration.includes('REVOKE ALL PRIVILEGES ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated'));
  assert.ok(migration.includes('GRANT EXECUTE ON FUNCTION graphql_public.graphql(text, text, jsonb, jsonb) TO service_role'));
  assert.ok(migration.includes("has_function_privilege('anon', v_function, 'EXECUTE')"));
  assert.ok(migration.includes("has_function_privilege('authenticated', v_function, 'EXECUTE')"));
  assert.ok(migration.includes("has_function_privilege('service_role', v_function, 'EXECUTE')"));
  assert.ok(migration.includes('GraphQL resolver ACL verification failed'));
  assert.doesNotMatch(migration, /INSERT INTO|UPDATE public\.stock|DELETE FROM public\.stock|TRUNCATE/i);
});

test('GraphQL ACL migration checks PUBLIC through ACL expansion rather than treating PUBLIC as a role', () => {
  const migrationPath = new URL('../supabase/migrations/20261025110500_orshap_verify_orphan_graphql_resolver_acl_live_v13958.sql', import.meta.url);
  const migration = fs.readFileSync(migrationPath, 'utf8');
  assert.ok(migration.includes('aclexplode(COALESCE(p.proacl, acldefault'));
  assert.ok(migration.includes('lacks owner privileges'), 'migration must fail clearly when the deployment role cannot alter the function ACL');
  assert.ok(migration.includes('acl.grantee = 0'));
  assert.doesNotMatch(migration, /has_function_privilege\(['"]public['"]/i);
});

test('application uses canonical storage-area reporting and retires legacy zone-section report RPCs', () => {
  assert.ok(app.includes("client.rpc('get_stock_summary_by_storage_area'"), 'active report page must use canonical storage-area RPC');
  assert.doesNotMatch(app, /get_stock_summary_report/);
  assert.doesNotMatch(app, /zone_id|section_id/);
  const migrationPath = new URL('../supabase/migrations/20261025102208_orshap_remove_legacy_zone_section_report_rpcs_v13958.sql', import.meta.url);
  const migration = fs.readFileSync(migrationPath, 'utf8');
  assert.match(migration, /DROP FUNCTION IF EXISTS public\.get_stock_summary_report\(timestamptz, timestamptz, uuid, uuid, uuid\)/);
  assert.match(migration, /DROP FUNCTION IF EXISTS public\.get_stock_summary_report_internal\(timestamptz, timestamptz, uuid, uuid, uuid\)/);
  assert.doesNotMatch(migration, /DELETE FROM|TRUNCATE|UPDATE public\.stock/i);
});

test('About page stat cards pass note and icon in the correct argument positions', () => {
  const start = app.indexOf('function aboutPage()');
  const end = app.indexOf('function ', start + 'function aboutPage()'.length);
  assert.ok(start >= 0 && end > start, 'About page renderer exists');
  const source = app.slice(start, end);
  assert.ok(source.includes("stat(tx('معادلات موثقة','Documented formulas'),String(formulas.length),tx('مرجع حسابي','Calculation reference'),'ⓘ')"));
  assert.ok(source.includes("stat(tx('أدوار RBAC','RBAC roles'),String(rbac.length),tx('مصفوفة الأدوار','Role matrix'),'⛨')"));
  assert.ok(source.includes("stat(tx('لغات الواجهة','UI languages'),'2',tx('العربية والإنجليزية','Arabic and English'),'文')"));
  assert.doesNotMatch(source, /stat\([^)]*,'[ⓘ⛨文]'\)/);
});

test('transaction modal never fabricates a reference when metadata is absent', () => {
  assert.ok(app.includes("state.v12TxMeta=state.v12TxMeta||{reference_no:'',transaction_type:'GRN'};"));
  assert.doesNotMatch(app, /reference_no:\s*'REF-'\s*\+\s*Date\.now\(\)/);
});

test('stock movement reference is database-generated and retryable without fabricated fallback', () => {
  const start = app.indexOf('async function v13RequestMovementReference(');
  const end = app.indexOf('function v13StockMovementModal()', start);
  assert.ok(start >= 0 && end > start, 'stock movement reference requester exists');
  const source = app.slice(start, end);
  assert.ok(source.includes("rpc('next_transaction_reference',{})"));
  assert.ok(source.includes('Reference request timed out'));
  assert.ok(source.includes('reference_error:true'));
  assert.ok(source.includes('v13-stock-movement-retry-reference'));
  const action = app.slice(app.indexOf("if(a==='v13-stock-movement')"), app.indexOf("if(a==='v13-stock-movement-save')"));
  assert.ok(action.includes("reference_no:''"), 'movement form must start without a fabricated reference');
  assert.ok(action.includes('void v13RequestMovementReference'));
  assert.ok(action.includes('v13-stock-movement-retry-reference'));
  assert.ok(!action.includes('Date.now()'), 'movement reference must not be generated in the browser');
});

test('stock movement dependent fields are handled by one canonical change listener', () => {
  assert.equal(
    (app.match(/if\(el\.closest\('#v13-stock-movement-form'\)&&el\.matches\('\[data-v13-movement-field\]'\)\)/g) || []).length,
    1,
    'the primary delegated change listener must own all movement field state updates'
  );
  assert.doesNotMatch(
    app,
    /if\(e\.target\.matches\('\[data-v13-movement-field\]'\)\)\{const f=document\.getElementById\('v13-stock-movement-form'\)/
  );
  const start = app.indexOf("if(el.closest('#v13-stock-movement-form')&&el.matches('[data-v13-movement-field]'))");
  const end = app.indexOf("if(el.id==='v12-wid'", start);
  assert.ok(start >= 0 && end > start, 'canonical movement change handler exists');
  const source = app.slice(start, end);
  assert.match(source, /state\.v13Movement=\{\.\.\.\(state\.v13Movement\|\|\{\}\),\.\.\.o\}/);
  assert.match(source, /source_warehouse_id','source_area_id','source_shelf_id','destination_warehouse_id','destination_area_id','destination_shelf_id/);
  assert.match(source, /state\.v13Movement\[prefix\+'_shelf_id'\]=''/);
});

test('legacy offline sync RPCs are retired until they respect transaction approval', () => {
  const migrationPath = new URL('../supabase/migrations/20261025122513_orshap_revoke_approval_bypassing_sync_rpcs_v13958.sql', import.meta.url);
  const migration = fs.readFileSync(migrationPath, 'utf8');
  assert.match(migration, /REVOKE ALL PRIVILEGES ON FUNCTION public\.process_sync_batch\(text, jsonb\)\s+FROM\s+PUBLIC, anon, authenticated/i);
  assert.match(migration, /REVOKE ALL PRIVILEGES ON FUNCTION public\.process_sync_batch_v2\(text, jsonb\)\s+FROM\s+PUBLIC, anon, authenticated/i);
  assert.match(migration, /has_function_privilege\('authenticated', v_legacy, 'EXECUTE'\)/);
  assert.match(migration, /has_function_privilege\('authenticated', v_v2, 'EXECUTE'\)/);
  for (const file of ['app.js', 'supabase-client.js', 'SQLite-db.js', 'sw.js']) {
    const source = fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8');
    assert.doesNotMatch(source, /process_sync_batch(?:_v2)?\s*\(/, file + ' must not depend on the retired RPC');
  }
});

test('offline voucher reference falls back to a clearly provisional local ID', () => {
  assert.match(app, /function v12SetLocalTransactionReference\(requestId\)/);
  assert.match(app, /const reference='LOCAL-'\+uid\(\)/);
  assert.match(app, /if\(!navigator\.onLine\)\{\s*if\(v12SetLocalTransactionReference\(requestId\)\)/);
});

test('outbox promotes a provisional voucher reference once and persists it before transaction creation', () => {
  const start = app.indexOf('async function flushOutbox()');
  const end = app.indexOf('\n  function say(', start);
  assert.ok(start >= 0 && end > start, 'outbox flush function exists');
  const source = app.slice(start, end);
  assert.ok(source.includes("if(/^LOCAL-/i.test(String(tx.reference_no||'')))"), 'only provisional local references are promoted');
  assert.match(source, /rpc\('next_transaction_reference',\{\}\)/);
  assert.ok(source.indexOf('outboxWrite(rows)') < source.indexOf("rpc('create_transaction_with_lines'"), 'official reference is persisted before the create RPC');
});

test('provisional references never go directly to transaction creation', () => {
  const start = app.indexOf('async function saveTx()');
  const end = app.indexOf('\n  function ', start + 20);
  assert.ok(start >= 0 && end > start, 'saveTx function exists');
  const source = app.slice(start, end);
  assert.match(source, /if\(!navigator\.onLine\|\|\/\^LOCAL-\/i\.test\(tx\.reference_no\)\)/);
  assert.ok(source.indexOf('outboxEnqueue(payload)') < source.indexOf("rpc('create_transaction_with_lines'"), 'provisional references are queued before any direct create RPC');
});

test('stocktake scope never invents zero-balance catalogue items at every shelf', () => {
  const start = app.indexOf('function c10BuildStocktakeLocationLines(');
  const end = app.indexOf('\nfunction c10Settle(', start);
  assert.ok(start >= 0 && end > start, 'stocktake location builder exists');
  const sandbox = {
    v5All: name => ({
      items: [{id:'item-stocked',code:'A'}, {id:'item-other',code:'B'}],
      shelves: [
        {id:'shelf-a',warehouse_id:'wh-a',storage_area_id:'area-a',is_active:true},
        {id:'shelf-b',warehouse_id:'wh-b',storage_area_id:'area-b',is_active:true}
      ],
      storage_areas: [
        {id:'area-a',warehouse_id:'wh-a',is_active:true},
        {id:'area-b',warehouse_id:'wh-b',is_active:true}
      ],
      stock: [{id:'st-1',item_id:'item-stocked',shelf_id:'shelf-a',quantity:4,batch_no:'B1'}]
    })[name] || []
  };
  vm.createContext(sandbox);
  vm.runInContext(app.slice(start,end),sandbox);
  const built=sandbox.c10BuildStocktakeLocationLines('wh-a',null);
  assert.equal(built.lines.length,1);
  assert.equal(built.lines[0].item_id,'item-stocked');
  assert.equal(built.lines[0].system_qty,4);
  assert.equal(sandbox.c10BuildStocktakeLocationLines('wh-a','area-b').lines.length,0,'cross-warehouse area filter must not widen or mis-scope the count');
});

test('issue smart warehouse suggestion moves away from an authorized warehouse with no stock', () => {
  const start=app.indexOf('function v13TxSuggestedWarehouse(');
  const end=app.indexOf('\nfunction v13TxOwnerChoices(',start);
  assert.ok(start>=0&&end>start,'smart warehouse resolver exists');
  const stockRows=[
    {item_id:'item-1',shelf_id:'shelf-b',quantity:7},
    {item_id:'item-1',shelf_id:'shelf-not-allowed',quantity:99}
  ];
  const sandbox={
    v13TxAllowedWarehouses:()=>[{id:'wh-a'},{id:'wh-b'}],
    v13TxStockRows:(itemId,warehouseId='')=>stockRows.filter(r=>r.item_id===itemId&&(!warehouseId||({'shelf-b':'wh-b','shelf-not-allowed':'wh-x'}[r.shelf_id]===warehouseId))),
    v5Find:(table,id)=>table==='shelves'?({'shelf-b':{id:'shelf-b',warehouse_id:'wh-b'},'shelf-not-allowed':{id:'shelf-not-allowed',warehouse_id:'wh-x'}}[id]):null
  };
  vm.createContext(sandbox);
  vm.runInContext(app.slice(start,end),sandbox);
  assert.equal(sandbox.v13TxSuggestedWarehouse('item-1','ISSUE','wh-a'),'wh-b');
  assert.equal(sandbox.v13TxSuggestedWarehouse('item-1','GRN','wh-a'),'wh-a','inbound vouchers may retain a valid manual warehouse selection');
});

test('stocktake counts queue offline and replay through the database count RPC', () => {
  assert.ok(app.includes('function stocktakeCountQueueKey(){'));
  assert.ok(app.includes('function queueStocktakeCount(line,n){'));
  assert.ok(app.includes("async function flushStocktakeCountQueue(){"));
  assert.ok(app.includes("await rpc('save_stocktake_count',{p_line_id:op.line_id,p_counted_qty:op.counted_qty})"));
  const start=app.indexOf('async function saveStocktakeCount(');
  const end=app.indexOf('\n  window.orshapV12=',start);
  const source=app.slice(start,end);
  assert.ok(source.includes('if(!navigator.onLine){'));
  assert.ok(source.includes('queueStocktakeCount(line,n)'));
  assert.ok(source.includes('isUuid(line.id)||!isUuid(session.id)'));
  const queueStart=app.indexOf('async function flushStocktakeCountQueue()');
  const queueEnd=app.indexOf('async function saveStocktakeCount(',queueStart);
  const queueSource=app.slice(queueStart,queueEnd);
  assert.match(queueSource,/!v13OfflineWarehouseAllowed\(session\.warehouse_id\)/,'queued count replay must require the single explicitly assigned offline warehouse');
  assert.ok(queueSource.indexOf('!v13OfflineWarehouseAllowed(session.warehouse_id)')<queueSource.indexOf("await rpc('save_stocktake_count'"),'scope check must happen before the RPC');
  assert.match(app,/if\(!c10AccessibleWarehouse\(session\.warehouse_id\)\)throw new Error\('This stocktake session is outside your assigned warehouse scope\.'\)/);
  assert.ok(app.includes('await window.orshapV12?.refresh?.();await window.orshapV12?.syncOfflineMasterQueue?.();'),'manual sync refreshes current assignment before replay');
  assert.ok(app.includes('refreshV12().then(ok=>{if(ok!==true)throw new Error('),'online event requires a confirmed current assignment before replay');
  assert.ok(app.indexOf('if(ok!==true)throw new Error')<app.indexOf('Promise.all([flushOutbox(),flushStocktakeCountQueue()])'),'online event must not flush queues after a failed refresh');
  const syncStart=app.indexOf("if(typeof c10DoSync==='function'){c10DoSync=async function()");
  const syncEnd=app.indexOf('// Keep selected stocktake line IDs explicit',syncStart);
  const syncSource=app.slice(syncStart,syncEnd);
  assert.ok(syncSource.indexOf('await window.orshapV12?.refresh?.()')<syncSource.indexOf('await window.orshapOutbox?.retry?.()'),'unified Sync refreshes access before transaction replay');
  assert.ok(syncSource.includes('await window.orshapV12?.syncStocktakeCountQueue?.()'),'unified Sync also retries the dedicated stocktake count queue');
  assert.ok(syncSource.includes('stocktakeCountQueueList?.()'),'unified Sync reports remaining queued counts');
});

test('stocktake database migration excludes unrelated catalogue items from zero-balance lines', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261025202940_orshap_stocktake_exclude_unassigned_catalogue_items_v13958.sql', import.meta.url), 'utf8');
  assert.ok(migration.includes('CREATE OR REPLACE FUNCTION public.populate_stocktake_session_lines_internal'));
  assert.ok(migration.includes('FROM public.stock AS st'));
  assert.ok(migration.includes('JOIN public.shelves AS sh'));
  assert.ok(migration.includes('JOIN public.storage_areas AS sa'));
  assert.ok(migration.includes('No stock rows exist in the selected stocktake scope'));
  assert.ok(!migration.includes('UNION ALL'));
  assert.ok(!migration.includes('FROM public.items i JOIN public.shelves'));
});


test('smart shelf suggestion picks a valid default while preserving eligible manual selection', () => {
  const start=app.indexOf('function v13TxShelfChoices(');
  const end=app.indexOf('function v13TxSuggestedWarehouse(',start);
  assert.ok(start>=0&&end>start,'shelf choice and suggestion helpers exist');
  const sandbox={
    v5All:(name)=>name==='shelves'?[{id:'shelf-a',warehouse_id:'wh-a'},{id:'shelf-b',warehouse_id:'wh-a'}]:name==='administrative_departments'?[]:[],
    v13TxShelfIsValid:()=>true,
    v13TxStockRows:()=>[{item_id:'item-1',shelf_id:'shelf-a',quantity:2},{item_id:'item-1',shelf_id:'shelf-b',quantity:8}],
    v5Find:(table,id)=>table==='shelves'?({'shelf-a':{id:'shelf-a',warehouse_id:'wh-a'},'shelf-b':{id:'shelf-b',warehouse_id:'wh-a'}}[id]):null
  };
  vm.createContext(sandbox);
  vm.runInContext(app.slice(start,end),sandbox);
  const choices=sandbox.v13TxShelfChoices('item-1','ISSUE','wh-a');
  assert.equal(choices.length,2);
  assert.equal(sandbox.v13TxSuggestedShelf('item-1','ISSUE','wh-a',choices),'shelf-b','issue should suggest the shelf with the most available stock');
});

test('stocktake blocks review submission when old unbacked zero-balance lines remain', () => {
  assert.ok(app.includes('const staleZeroLines=lines.filter('));
  assert.ok(app.includes('!staleZeroLines.length'), 'review submission is blocked until a clean session is used');
  assert.ok(app.includes('no matching stock row at the selected shelf') || app.includes('لا يقابلها رصيد صنف في الرف المحدد'));
});

test('new request modal keeps long item tables inside a scrollable viewport', () => {
  assert.ok(css.includes('.modal {\n  display:flex;\n  flex-direction:column;'));
  assert.ok(css.includes('  .modal,.modal-wide {\n    display:flex;\n    flex-direction:column;'));
  assert.ok(css.includes('overflow-y:auto;'));
});


test('offline stocktake count queue is visible and retryable from the unified Sync screen', () => {
  assert.ok(app.includes("source:'stocktake',table:'stocktake_lines',operation:'save_stocktake_count'"));
  assert.ok(app.includes("'orshap_stocktake_count_queue_v1:'+sid"));
  assert.ok(app.includes("'orshap_stocktake_count_queue_v1:'+sid])"), 'Retry errors must reset stocktake queue errors too');
  assert.ok(app.includes('syncStocktakeCountQueue:flushStocktakeCountQueue'));
  assert.ok(app.includes('await window.orshapV12?.syncStocktakeCountQueue?.()'), 'Sync Now must flush queued stocktake counts');
});


test('stale out-of-scope zero-balance stocktake lines stay blocked even after they are counted', () => {
  const start=app.indexOf('const staleZeroLines=lines.filter(');
  const end=app.indexOf(';',start);
  const expression=app.slice(start,end+1);
  assert.ok(start>=0&&end>start);
  assert.ok(!expression.includes('l.counted_qty'), 'counting a stale line must not make it eligible for review');
  assert.ok(expression.includes('Number(l.system_qty||0)===0'));
  assert.ok(expression.includes("st.item_id===l.item_id&&st.shelf_id===l.shelf_id"));
});


test('explicit warehouse assignments constrain administrator dropdown scope', () => {
  const start=app.indexOf('function c10AccessibleWarehouse(');
  const end=app.indexOf('\nfunction c10Audit(',start);
  assert.ok(start>=0&&end>start,'warehouse access predicate exists');
  const sandbox={state:{session:{id:'admin-1',role:'SUPER_ADMIN',profile:{role:'SUPER_ADMIN',assigned_warehouse_ids:['wh-a']}}}};
  vm.createContext(sandbox);
  vm.runInContext(app.slice(start,end),sandbox);
  assert.equal(sandbox.c10AccessibleWarehouse('wh-a'),true,'explicitly assigned warehouse remains accessible');
  assert.equal(sandbox.c10AccessibleWarehouse('wh-b'),false,'super admin assignment must not be bypassed');
  sandbox.state.session.profile.assigned_warehouse_ids=[];
  assert.equal(sandbox.c10AccessibleWarehouse('wh-b'),true,'unrestricted admin with no assignment list retains global access');
  sandbox.state.session={id:'manager-1',role:'MANAGER',profile:{role:'MANAGER',assigned_warehouse_ids:[]}};
  assert.equal(sandbox.c10AccessibleWarehouse('wh-a'),false,'manager without an explicit assignment is not implicitly global');
  sandbox.state.session={id:'user-1',role:'USER',profile:{role:'USER',assigned_warehouse_ids:[]}};
  assert.equal(sandbox.c10AccessibleWarehouse('wh-a'),false,'non-admin without assignments has no warehouse access');
});

test('transaction warehouse dropdown respects explicit administrator assignment', () => {
  const helperStart=app.indexOf('function c10AccessibleWarehouse(');
  const helperEnd=app.indexOf('\nfunction c10Audit(',helperStart);
  const dropdownStart=app.indexOf('function v13TxAllowedWarehouses()');
  const dropdownEnd=app.indexOf('\nfunction v13TxShelfIsValid',dropdownStart);
  assert.ok(helperStart>=0&&helperEnd>helperStart,'warehouse access predicate exists');
  assert.ok(dropdownStart>=0&&dropdownEnd>dropdownStart,'transaction warehouse resolver exists');
  const sandbox={state:{session:{id:'admin-1',role:'SUPER_ADMIN',profile:{role:'SUPER_ADMIN',assigned_warehouse_ids:['wh-a']}}},v5All:(table)=>table==='warehouses'?[{id:'wh-a'},{id:'wh-b'}]:[]};
  vm.createContext(sandbox);
  vm.runInContext(app.slice(helperStart,helperEnd)+'\n'+app.slice(dropdownStart,dropdownEnd),sandbox);
  assert.deepEqual(Array.from(sandbox.v13TxAllowedWarehouses(),w=>w.id),['wh-a']);
});

test('stocktake session list and active session are restricted to accessible warehouses', () => {
  const start=app.indexOf('function c10Stocktake()');
  const end=app.indexOf('\nfunction c10BuildStocktakeLocationLines',start);
  assert.ok(start>=0&&end>start,'stocktake renderer exists');
  const source=app.slice(start,end);
  assert.match(source,/sessions=v5All\('stocktake_sessions'\)\.filter\(s=>c10AccessibleWarehouse\(s\.warehouse_id\)\)/);
  assert.match(source,/active=activeCandidate&&c10AccessibleWarehouse\(activeCandidate\.warehouse_id\)\?activeCandidate:null/);
});

test('offline transaction outbox permits only receipts and issues; stocktake uses its own queue', () => {
  assert.match(app, /function v13OfflineTransactionAllowed\(type\)\{return \['GRN','ISSUE'\]/);
  assert.match(app, /const offlineEligible=v13OfflineTransactionAllowed\(tx\.transaction_type\)/);
  assert.match(app, /if\(!c10AccessibleWarehouse\(tx\.warehouse_id\)\)throw new Error\(state\.lang==='ar'\?'المستودع المحدد خارج نطاق المستودعات المعيّنة لحسابك\.'/,'transaction entry fails closed before creating a local outbox record');
  assert.match(app, /Offline mode requires a single explicitly assigned warehouse and supports receipts\/issues only/);
  assert.match(app, /!v13OfflineTransactionAllowed\(tx\.transaction_type\)/);
  assert.match(app, /function outboxOverlay\(\)[\s\S]*?v13OfflineWarehouseAllowed\(tx\.warehouse_id\)/);
  assert.match(app, /orshap_stocktake_count_queue_v1/);
});

test('warehouse scope migration hardens RLS reads and SECURITY DEFINER write paths', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261026044604_orshap_enforce_assigned_warehouse_scope_v13958.sql', import.meta.url), 'utf8');
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.current_user_can_access_warehouse/);
  assert.match(migration, /trg_enforce_transaction_warehouse_scope/);
  assert.match(migration, /trg_enforce_stocktake_warehouse_scope/);
  assert.match(migration, /DROP POLICY IF EXISTS transactions_permission_select/);
  assert.match(migration, /DROP POLICY IF EXISTS stocktake_sessions_permission_select/);
  assert.match(migration, /DROP POLICY IF EXISTS stock_authenticated_read/);
  assert.match(migration, /current_user_can_create_warehouse/);
  assert.match(migration, /WITH CHECK \(public\.current_user_has_permission\('action:facility:manage'\) AND public\.current_user_can_access_warehouse\(warehouse_id\)\)/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.list_stocktake_lines_secure/);
  assert.match(migration, /WHERE public\.current_user_can_access_warehouse\(s\.warehouse_id\)/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.get_stock_summary_by_storage_area/);
  assert.match(migration, /Report warehouse is outside the current user assigned scope/);
  assert.match(migration, /DROP POLICY IF EXISTS transaction_audit_select_policy/);
  assert.match(migration, /DROP POLICY IF EXISTS audit_logs_select_policy/);
  assert.match(migration, /DROP POLICY IF EXISTS archive_movements_active_read/);
  assert.match(migration, /archive_movements_manager_insert[\s\S]*?current_user_can_access_warehouse\(warehouse_id\)/);
  assert.match(migration, /DROP POLICY IF EXISTS stock_transfers_select_assigned/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS public\.wms_transfer_scope_context/);
  assert.match(migration, /REVOKE ALL ON TABLE public\.wms_transfer_scope_context FROM PUBLIC, anon, authenticated/);
  assert.match(migration, /c\.transaction_id=txid_current\(\) AND c\.actor_id=auth\.uid\(\)/);
  assert.doesNotMatch(migration, /orshap\.transfer_scope_bypass/, 'a client-settable GUC must not authorize cross-warehouse writes');
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.reject_stock_transfer_receipt/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.finalize_stock_transfer_source_issue/);
  assert.match(migration, /received\+returned quantities reconcile/);
});



test('approval and rejection RPCs enforce explicit warehouse assignment for privileged roles', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261026045733_orshap_transaction_rpc_enforce_assigned_warehouse_scope_v13958.sql', import.meta.url), 'utf8');
  const helperAcl = fs.readFileSync(new URL('../supabase/migrations/20261026044833_restrict_assigned_warehouse_scope_helper_execution_v13958.sql', import.meta.url), 'utf8');
  assert.match(migration, /IF NOT public\.current_user_can_access_warehouse\(v_tx_rec\.warehouse_id\)/);
  assert.match(migration, /IF NOT public\.current_user_can_access_warehouse\(v_tx\.warehouse_id\)/);
  assert.match(migration, /IF NOT public\.current_user_can_access_warehouse\(v_warehouse_id\)/);
  assert.match(migration, /IF NOT public\.current_user_can_access_warehouse\(p_warehouse_id\)/);
  assert.match(migration, /IF NOT public\.current_user_can_access_warehouse\(v_session\.warehouse_id\)/);
  assert.match(migration, /IF NOT public\.current_user_can_access_warehouse\(v_s\.warehouse_id\)/);
  assert.doesNotMatch(migration, /NOT public\.current_user_is_manager\(\)\s+AND NOT \(v_s\.warehouse_id/);
  assert.doesNotMatch(migration, /v_actor_role NOT IN \('SUPER_ADMIN', 'ADMIN', 'MANAGER'\)\s+AND NOT EXISTS/);
  assert.ok(migration.indexOf('current_user_can_access_warehouse(v_tx.warehouse_id)') < migration.indexOf("IF v_tx.status <> 'PENDING_APPROVAL'"), 'rejection scope guard runs before status-specific behavior');
  assert.match(helperAcl, /REVOKE ALL ON FUNCTION public\.current_user_can_access_warehouse\(uuid\) FROM PUBLIC, anon/);
  assert.match(helperAcl, /GRANT EXECUTE ON FUNCTION public\.current_user_can_access_warehouse\(uuid\) TO authenticated, service_role/);
});

test('cached warehouse-bound records are hidden outside the current assignment', () => {
  const helperStart=app.indexOf('function c10AccessibleWarehouse(');
  const helperEnd=app.indexOf('function v13OfflineTransactionAllowed',helperStart);
  const allStart=app.indexOf('function v5All(k){');
  const allEnd=app.indexOf('\nfunction v5Find(',allStart);
  assert.ok(helperStart>=0&&helperEnd>helperStart&&allStart>=0&&allEnd>allStart);
  const sandbox={
    state:{session:{id:'admin-1',role:'SUPER_ADMIN',profile:{role:'SUPER_ADMIN',assigned_warehouse_ids:['wh-a']}}},
    V5_DB:{
      warehouses:[{id:'wh-a'},{id:'wh-b'}],
      storage_areas:[{id:'a-area',warehouse_id:'wh-a'},{id:'b-area',warehouse_id:'wh-b'}],
      shelves:[{id:'a-shelf',warehouse_id:'wh-a'},{id:'b-shelf',warehouse_id:'wh-b'}],
      stock:[{id:'a-stock',shelf_id:'a-shelf'},{id:'b-stock',shelf_id:'b-shelf'}],
      transactions:[{id:'a-tx',warehouse_id:'wh-a'},{id:'b-tx',warehouse_id:'wh-b'}],
      transaction_lines:[{id:'a-line',transaction_id:'a-tx'},{id:'b-line',transaction_id:'b-tx'}],
      stocktake_sessions:[{id:'a-session',warehouse_id:'wh-a'},{id:'b-session',warehouse_id:'wh-b'}],
      stocktake_lines:[{id:'a-count',session_id:'a-session'},{id:'b-count',session_id:'b-session'}],
      stocktake_logs:[],inventory_ledger:[{id:'a-ledger',warehouse_id:'wh-a'},{id:'b-ledger',warehouse_id:'wh-b'}],
      transaction_ledger:[{id:'a-tledger',warehouse_id:'wh-a'},{id:'b-tledger',warehouse_id:'wh-b'}],
      transaction_audit:[{id:'a-audit',transaction_id:'a-tx'},{id:'b-audit',transaction_id:'b-tx'}],
      audit_logs:[{id:'b-log',warehouse_id:'wh-b'},{id:'tx-log',details:{tx_id:'b-tx'}},{id:'global-log'}],
      archive_movements:[{id:'a-archive',warehouse_id:'wh-a'},{id:'b-archive',warehouse_id:'wh-b'}],
      archive_balances:[{id:'a-balance',warehouse_id:'wh-a'},{id:'b-balance',warehouse_id:'wh-b'}],
      stock_transfers:[],stock_transfer_orders:[]
    }
  };
  vm.createContext(sandbox);
  vm.runInContext(app.slice(helperStart,helperEnd)+'\n'+app.slice(allStart,allEnd),sandbox);
  assert.deepEqual(Array.from(sandbox.v5All('warehouses'),x=>x.id),['wh-a']);
  assert.deepEqual(Array.from(sandbox.v5All('transactions'),x=>x.id),['a-tx']);
  assert.deepEqual(Array.from(sandbox.v5All('transaction_lines'),x=>x.id),['a-line']);
  assert.deepEqual(Array.from(sandbox.v5All('stocktake_lines'),x=>x.id),['a-count']);
  assert.deepEqual(Array.from(sandbox.v5All('inventory_ledger'),x=>x.id),['a-ledger']);
  assert.deepEqual(Array.from(sandbox.v5All('transaction_audit'),x=>x.id),['a-audit']);
  assert.deepEqual(Array.from(sandbox.v5All('archive_movements'),x=>x.id),['a-archive']);
  assert.deepEqual(Array.from(sandbox.v5All('audit_logs'),x=>x.id),['global-log'],'warehouse-specific and transaction-linked audit logs are hidden');
});


test('profile refresh applies server-derived role warehouse scope and purges out-of-scope cache', () => {
  const start=app.indexOf('const current=V12.remoteState.profiles.find');
  const end=app.indexOf('    outboxOverlay();',start);
  assert.ok(start>=0&&end>start,'profile refresh and cache purge block exists');
  const source=app.slice(start,end);
  assert.match(source,/current_user_accessible_warehouse_ids/,'effective role and user scope comes from the server');
  assert.match(source,/accessible_warehouse_ids/,'server-derived scope is cached for offline use');
  assert.match(source,/if\(allow\.size\)/,'only permitted warehouses remain in cache');
  assert.match(source,/else\{/,'an empty effective scope purges warehouse-bound cache');
  assert.match(source,/db\.transactions=\(db\.transactions\|\|\[\]\)\.filter/);
  assert.doesNotMatch(source,/db\.items\s*=\s*db\.items\.filter/,'item master remains warehouse-independent');
});

test('client warehouse predicate honors a server-derived empty or selected scope', () => {
  const start=app.indexOf('function c10AccessibleWarehouse(id){');
  const end=app.indexOf('\nfunction v13OfflineTransactionAllowed',start);
  assert.ok(start>=0&&end>start,'warehouse access predicate exists');
  const source=app.slice(start,end);
  assert.match(source,/Array\.isArray\(p\.accessible_warehouse_ids\)/);
  assert.match(source,/cachedProfile/,'offline predicate falls back to the cached profile scope');
  assert.match(source,/if\(accessible\)return id\?accessible\.includes\(id\):accessible\.length>0/);
});
test('role permissions modal restores configurable one-or-many warehouse scope', () => {
  assert.match(app, /v12-role-scope-mode/);
  assert.match(app, /id:'SELECTED',name:tr\(/);
  assert.match(app, /One or multiple selected warehouses/);
  assert.match(app, /admin_save_role_access_config/);
  assert.match(app, /admin_list_warehouses_for_role_scope/);
  assert.match(app, /role_warehouse/);
});

test('role warehouse scope migration defaults to inheritance and intersects explicit user assignment', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261026055048_orshap_restore_configurable_role_warehouse_scope_v13958.sql', import.meta.url), 'utf8');
  assert.match(migration, /scope_mode IN \('INHERIT','SELECTED','ALL'\)/);
  assert.match(migration, /current_user_can_access_warehouse/);
  assert.match(migration, /p_warehouse_id = ANY\(p\.assigned_warehouse_ids\)/);
  assert.match(migration, /p_warehouse_id = ANY\(rs\.warehouse_ids\)/);
  assert.match(migration, /admin_save_role_access_config/);
  assert.match(migration, /admin_list_warehouses_for_role_scope/);
  assert.match(migration, /REVOKE ALL ON TABLE public\.role_warehouse_scopes FROM PUBLIC, anon, authenticated/);
});


test('effective warehouse scope RPC drives client filtering and fails closed', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261026060145_orshap_expose_effective_warehouse_scope_v13958.sql', import.meta.url), 'utf8');
  assert.match(migration, /current_user_accessible_warehouse_ids/);
  assert.match(migration, /current_user_can_access_warehouse\(w\.id\)/);
  assert.match(migration, /REVOKE ALL ON FUNCTION public\.current_user_accessible_warehouse_ids\(\) FROM PUBLIC, anon/);
  assert.match(app, /scopeClient\.rpc\('current_user_accessible_warehouse_ids'\)/);
  assert.match(app, /current\.accessible_warehouse_ids=\[\.\.\.new Set\(accessibleWarehouseIds\)\]/);
  assert.match(app, /catch\(scopeError\)[\s\S]*accessibleWarehouseIds=\[\]/,'online scope refresh failure must fail closed');
});


test('transfer and return RPCs enforce configured warehouse role scope', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261026060257_orshap_enforce_role_scope_transfer_rpcs_v13958.sql', import.meta.url), 'utf8');
  assert.match(migration, /dispatch_stock_transfer_order_v2/);
  assert.match(migration, /receive_stock_transfer_quantity_at_shelf_v2/);
  assert.match(migration, /review_stock_transfer_return_request/);
  assert.match(migration, /confirm_stock_transfer_return/);
  assert.match(migration, /create_stock_return_request/);
  assert.match(migration, /current_user_can_access_warehouse\(p_source_warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_transfer\.destination_warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_t\.source_warehouse_id\)/);
  assert.match(migration, /Expected exactly one patch anchor/,'migration must fail closed if live function definitions differ');
});

test('offline transaction and stocktake queues require exactly one explicitly assigned warehouse', () => {
  assert.match(app, /function v13OfflineWarehouseAllowed\(id\)/);
  assert.match(app, /assigned\.length===1&&assigned\[0\]===id&&c10AccessibleWarehouse\(id\)/);
  assert.match(app, /v13OfflineTransactionAllowed\(tx\.transaction_type\)\|\|!v13OfflineWarehouseAllowed\(tx\.warehouse_id\)/);
  assert.match(app, /Offline transaction requires exactly one explicitly assigned warehouse/);
  assert.match(app, /!v13OfflineWarehouseAllowed\(session\.warehouse_id\)/);
  assert.match(app, /Offline stocktake counts require exactly one explicitly assigned warehouse/);
  assert.match(app, /Offline transaction is outside the current user or assigned warehouse scope|Offline transaction requires exactly one explicitly assigned warehouse/);
});

test('approval stock-key locking and internal transfer scope alignment are fail-closed', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261026070000_orshap_serialize_stock_key_approval_v13958.sql', import.meta.url), 'utf8');
  assert.match(migration, /pg_advisory_xact_lock\(hashtextextended\(/);
  assert.match(migration, /v_rec\.item_id::text\s*\|\| ':' \|\| v_rec\.shelf_id::text/);
  assert.match(migration, /Expected exactly one stock-key read anchor in approve_transaction/);
  assert.match(migration, /dispatch_stock_transfer_with_destination_warehouse_owner_aware/);
  assert.match(migration, /receive_stock_transfer_quantity_at_shelf_v2/);
  assert.match(migration, /confirm_stock_transfer_return_v2\(uuid\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_src\.warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_t\.destination_warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_t\.source_warehouse_id\)/);
});

test('RLS writes for transactions and stocktake consistently enforce effective warehouse scope', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261026070000_orshap_serialize_stock_key_approval_v13958.sql', import.meta.url), 'utf8');
  for (const policy of [
    'stocktake_sessions_permission_insert','stocktake_sessions_permission_update','stocktake_sessions_permission_delete',
    'transactions_permission_insert','transactions_permission_update','transactions_permission_delete',
    'transaction_lines_permission_insert','transaction_lines_permission_update','transaction_lines_permission_delete',
    'stocktake_lines_permission_insert','stocktake_lines_permission_update','stocktake_lines_permission_delete'
  ]) assert.match(migration, new RegExp('ALTER POLICY ' + policy + ' ON public\\.'));
  assert.match(migration, /current_user_can_access_warehouse\(warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(t\.warehouse_id\)/);
  assert.match(migration, /current_user_can_access_warehouse\(s\.warehouse_id\)/);
});

test('user administration exposes warehouse-name multi-select and persists selected warehouse IDs', () => {
  const start=app.indexOf('function s81UserModal(id)');
  const end=app.indexOf('function s81Units()',start);
  assert.ok(start>=0&&end>start,'user modal and save functions exist');
  const source=app.slice(start,end);
  assert.match(source,/v5All\('warehouses'\)/,'choices come from warehouses available within current access scope');
  assert.match(source,/name="user_assigned_warehouse"/,'each warehouse is a selectable checkbox');
  assert.match(source,/selected\.has\(w\.id\)/,'existing assignments remain checked when editing');
  assert.match(source,/querySelectorAll\('input\[name="user_assigned_warehouse"\]:checked'\)/,'save reads every selected warehouse');
  assert.match(source,/assigned_warehouse_ids:assignedWarehouseIds/,'save persists a deduplicated ID array');
  assert.doesNotMatch(source,/Assigned Warehouse IDs \(comma separated\)/,'no manual comma-separated IDs field remains');
});

test('user warehouse assignment uses server catalogue and supports multiple checkboxes', () => {
  const start = app.indexOf('async function userWarehouseModal(id)');
  const end = app.indexOf('async function saveUserWarehouses(id)', start);
  assert.ok(start >= 0 && end > start, 'user warehouse assignment functions exist');
  const source = app.slice(start, end);
  assert.match(source, /rpc\('admin_list_warehouses_for_role_scope'\)/);
  assert.match(source, /type="checkbox" name="wh"/);
  assert.match(source, /Select all/);
  assert.match(source, /Clear all/);
  assert.match(app, /p_assigned_warehouse_ids:vals/);
  assert.match(app, /v12-user-wh-all/);
  assert.match(app, /v12-user-wh-none/);
  assert.match(css, /\.v12-user-wh-option input\[type=checkbox\]\{width:18px!important/);
});


test('opening balances require an active owning department through create and approval paths', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261026073407_orshap_require_opening_balance_owner_v13958.sql', import.meta.url), 'utf8');
  assert.ok(migration.includes('create_transaction_with_lines(uuid,jsonb,jsonb)'));
  assert.ok(migration.includes('approve_transaction(uuid)'));
  assert.ok(migration.includes("'OPENING_BALANCE'"));
  assert.ok(migration.includes('administrative_departments d'));
  assert.ok(migration.includes('d.is_active = true'));
  assert.ok(migration.includes('Owning department is required for each stock transaction line'));
  assert.ok(migration.includes("WHEN 'OPENING_BALANCE' THEN current_user_has_permission('action:transaction:adjustment:create')"));
  assert.ok(migration.includes("p.role IN ('SUPER_ADMIN','MANAGER')"));
  assert.ok(migration.includes('current_user_can_access_warehouse(warehouse_id)'));
  assert.ok(migration.includes('Expected exactly one owning-department validation clause in %'));
});

test('super-admin user assignment loads all warehouse choices and preserves hidden out-of-scope assignments', () => {
  const start=app.indexOf('async function s81UserModal(id)');
  const end=app.indexOf('function s81Units()',start);
  assert.ok(start>=0&&end>start,'async user modal and save functions exist');
  const source=app.slice(start,end);
  assert.match(source,/actorRole==='SUPER_ADMIN'/,'super-admin path is explicit');
  assert.ok(source.includes("client.rpc('admin_list_warehouses_for_role_scope')"),'super-admin gets the complete warehouse list from the authorized RPC');
  assert.match(source,/name="user_assigned_warehouse"/,'warehouse choices are multi-select checkboxes');
  assert.match(source,/retainedOutsideScope/,'edits by scoped administrators preserve assignments they cannot view');
  assert.match(source,/assigned_warehouse_ids:assignedWarehouseIds/,'save persists the merged assignment ID array');
});

test('reconnect handler does not flush transaction or stocktake queues when refresh returns false', () => {
  const at = app.indexOf("window.addEventListener('online',()=>{if(state.offlineSession)return;setTimeout(()=>refreshV12()");
  const end = app.indexOf("window.addEventListener('orshap-outbox-changed'", at);
  assert.ok(at >= 0 && end > at, 'online reconnect handler exists');
  const handler = app.slice(at, end);
  assert.ok(handler.includes('then(ok=>{if(ok!==true)throw new Error('), 'false refresh result must reject reconnect sync');
  assert.ok(handler.indexOf('if(ok!==true)throw new Error') < handler.indexOf('Promise.all([flushOutbox(),flushStocktakeCountQueue()])'), 'queues must not flush before confirmed refresh');
});

test('stocktake count SECURITY DEFINER RPC enforces the same session owner/manager boundary as RLS', () => {
  const migration = fs.readFileSync(new URL('../supabase/migrations/20261026082014_orshap_stocktake_count_session_owner_guard_v13958.sql', import.meta.url), 'utf8');
  assert.match(migration, /v_session\.created_by IS DISTINCT FROM v_user[\s\S]{0,120}NOT public\.current_user_is_manager\(\)/);
  assert.match(migration, /current_user_can_access_warehouse\(v_session\.warehouse_id\)/);
  assert.match(migration, /current_user_has_permission\('action:stocktake:count'\)/);
  assert.match(migration, /SECURITY DEFINER/);
});

test('offline master queue rejects unsupported tables and malformed operations without sending them', () => {
  const start = app.indexOf('async function syncOfflineMasterQueue()');
  const end = app.indexOf('async function rpc(', start);
  assert.ok(start >= 0 && end > start, 'master queue sync exists');
  const sync = app.slice(start, end);
  assert.ok(sync.includes("if(op.status==='CONFLICT'||op.status==='ERROR')"), 'conflicts and prior errors stay for review');
  assert.ok(sync.includes('!OFFLINE_MASTER_TABLES.has(op.table)'), 'unknown table names are rejected before network calls');
  assert.ok(sync.includes("!['insert','update','delete'].includes(op.kind)"), 'unknown operations are rejected');
  assert.ok(sync.includes("delete patch[pk]"), 'updates cannot change a primary key');
  assert.ok(sync.indexOf('!OFFLINE_MASTER_TABLES.has(op.table)') < sync.indexOf('s.from(op.table)'), 'table validation precedes database calls');
});

test('offline replay aborts all queue processing when authoritative refresh fails', () => {
  const refreshStart = app.indexOf('async function refreshV12()');
  const refreshEnd = app.indexOf('function qrPrint(', refreshStart);
  assert.ok(refreshStart >= 0 && refreshEnd > refreshStart, 'refresh function exists');
  const refresh = app.slice(refreshStart, refreshEnd);
  assert.ok(refresh.includes("return true}catch(e){say(e.message||String(e),'Refresh failed','error');return false}"), 'refresh must expose failure to its caller');
  const syncStart = app.lastIndexOf("if(typeof c10DoSync==='function')");
  const syncEnd = app.indexOf('// Keep selected stocktake line IDs explicit', syncStart);
  const sync = app.slice(syncStart, syncEnd);
  assert.ok(sync.includes('const scopeRefreshSucceeded=await window.orshapV12?.refresh?.();'));
  assert.ok(sync.includes('if(scopeRefreshSucceeded!==true)throw new Error('), 'failed authoritative refresh must abort sync');
  assert.ok(sync.indexOf('if(scopeRefreshSucceeded!==true)throw new Error') < sync.indexOf('await window.orshapV12?.syncOfflineMasterQueue?.()'));
  assert.ok(sync.indexOf('if(scopeRefreshSucceeded!==true)throw new Error') < sync.indexOf('await window.orshapOutbox?.retry?.()'));
  assert.ok(sync.includes('const finalRefreshSucceeded=await window.orshapV12?.refresh?.();'));
  assert.ok(sync.includes('if(finalRefreshSucceeded!==true)throw new Error('), 'post-sync refresh failure must not be reported as success');
  const onlineStart = app.indexOf("window.addEventListener('online',()=>{if(state.offlineSession)return;setTimeout(()=>refreshV12()");
  const onlineEnd = app.indexOf("window.addEventListener('orshap-outbox-changed'", onlineStart);
  assert.ok(onlineStart >= 0 && onlineEnd > onlineStart, 'online reconnect handler exists');
  const online = app.slice(onlineStart, onlineEnd);
  assert.ok(online.includes('then(ok=>{if(ok!==true)throw new Error('), 'reconnect must require successful refresh');
  assert.ok(online.indexOf('if(ok!==true)throw new Error') < online.indexOf('Promise.all([flushOutbox(),flushStocktakeCountQueue()])'), 'reconnect queues must remain stopped after refresh failure');
});

test('offline replay refreshes server-derived warehouse scope before transaction and stocktake queues', () => {
  const pullStart = app.indexOf('async function v12PullCore()');
  const pullEnd = app.indexOf('function inventoryV12()', pullStart);
  assert.ok(pullStart >= 0 && pullEnd > pullStart, 'canonical server refresh exists');
  const pull = app.slice(pullStart, pullEnd);
  assert.ok(pull.indexOf("rpc('current_user_accessible_warehouse_ids')") >= 0, 'effective scope comes from the authenticated database RPC');
  assert.ok(pull.indexOf('catch(scopeError)') < pull.indexOf('current.accessible_warehouse_ids=[...new Set(accessibleWarehouseIds)]'));
  assert.match(pull, /catch\(scopeError\)[\s\S]{0,260}accessibleWarehouseIds=\[\]/, 'scope lookup failure must fail closed');
  const refreshStart = app.indexOf('async function refreshV12()');
  const refreshEnd = app.indexOf('function qrPrint(', refreshStart);
  assert.ok(refreshStart >= 0 && refreshEnd > refreshStart, 'refresh path exists');
  const refresh = app.slice(refreshStart, refreshEnd);
  assert.ok(refresh.indexOf('await v12PullCore()') < refresh.indexOf('await flushOutbox()'), 'transaction outbox must wait for fresh scope');
  assert.ok(refresh.indexOf('await v12PullCore()') < refresh.indexOf('await flushStocktakeCountQueue()'), 'stocktake queue must wait for fresh scope');
  const syncStart = app.lastIndexOf("if(typeof c10DoSync==='function')");
  const syncEnd = app.indexOf('// Keep selected stocktake line IDs explicit', syncStart);
  assert.ok(syncStart >= 0 && syncEnd > syncStart, 'active sync override exists');
  const sync = app.slice(syncStart, syncEnd);
  assert.ok(sync.indexOf('await window.orshapV12?.refresh?.()') < sync.indexOf('await window.orshapOutbox?.retry?.()'));
  assert.ok(sync.indexOf('await window.orshapV12?.refresh?.()') < sync.indexOf('await window.orshapV12?.syncStocktakeCountQueue?.()'));
  assert.match(app, /if\(!v13OfflineWarehouseAllowed\(tx\.warehouse_id\)\|\|tx\.created_by!==state\.session\.id\)/);
  assert.match(app, /!v13OfflineWarehouseAllowed\(session\.warehouse_id\)/);
});
